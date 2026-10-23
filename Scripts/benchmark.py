#!/usr/bin/env python3
"""Measure the real macOS GUI process against an isolated local BitTorrent seed.

Run outside a restrictive network sandbox; an isolated QA app copy is launched:
  python3 Scripts/benchmark.py --app build/TorrentFlow.app

CPU is derived from proc_pidinfo cumulative user+system Mach ticks, converted
to nanoseconds with mach_timebase_info (essential on Apple silicon). A value of
100% denotes one fully occupied CPU core. RSS and physical footprint are reported
separately. The seeder, Python sampler, and compiler are separate processes.
"""
import argparse
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import statistics
import struct
import shutil
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
MIB = 1024 * 1024

class TaskInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint64) for name in
                ('virtual_size', 'resident_size', 'total_user', 'total_system', 'threads_user', 'threads_system')]
    _fields_ += [(name, ctypes.c_int32) for name in
                 ('policy', 'faults', 'pageins', 'cow_faults', 'messages_sent', 'messages_received',
                  'syscalls_mach', 'syscalls_unix', 'csw', 'threadnum', 'numrunning', 'priority')]

class RUsageInfoV0(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in
        ('user_time', 'system_time', 'pkg_idle_wkups', 'interrupt_wkups', 'pageins', 'wired_size',
         'resident_size', 'phys_footprint', 'proc_start_abstime', 'proc_exit_abstime')]

class MachTimebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]

class Sampler:
    def __init__(self, pid):
        self.pid = pid
        self.lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        self.lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_pidinfo.restype = ctypes.c_int
        self.lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self.lib.proc_pid_rusage.restype = ctypes.c_int
        timebase = MachTimebase()
        system = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
        if system.mach_timebase_info(ctypes.byref(timebase)) != 0 or not timebase.denom:
            raise RuntimeError('mach_timebase_info failed')
        self.timebase_numer = timebase.numer
        self.timebase_denom = timebase.denom
        self.previous = None
    def sample(self, phase):
        task = TaskInfo()
        length = self.lib.proc_pidinfo(self.pid, 4, 0, ctypes.byref(task), ctypes.sizeof(task))
        if length != ctypes.sizeof(task):
            raise RuntimeError('proc_pidinfo failed for GUI pid %s (errno %s)' % (self.pid, ctypes.get_errno()))
        now = time.monotonic()
        cpu_ticks = task.total_user + task.total_system
        cpu_ns = cpu_ticks * self.timebase_numer / self.timebase_denom
        result = {'time': now, 'phase': phase, 'cpu_total_ticks': cpu_ticks, 'cpu_total_ns': cpu_ns,
                  'rss_mib': task.resident_size / MIB, 'threads': task.threadnum}
        usage = RUsageInfoV0()
        if self.lib.proc_pid_rusage(self.pid, 0, ctypes.byref(usage)) == 0:
            result['footprint_mib'] = usage.phys_footprint / MIB
        if self.previous:
            dt = now - self.previous['time']
            result['interval_s'] = dt
            result['cpu_percent'] = max(0.0, (cpu_ns - self.previous['cpu_total_ns']) / 1e9 / dt * 100)
        self.previous = result
        return result

def percentile(values, p):
    values = sorted(values)
    if not values:
        return None
    return values[min(len(values) - 1, max(0, math.ceil(len(values) * p) - 1))]

def summary(samples, phase):
    rows = [s for s in samples if s['phase'] == phase and 'cpu_percent' in s]
    if not rows:
        raise RuntimeError('No samples for phase ' + phase)
    cpu = [s['cpu_percent'] for s in rows]
    rss = [s['rss_mib'] for s in rows]
    footprint = [s.get('footprint_mib', 0) for s in rows]
    durations = [s['interval_s'] for s in rows]
    return {'samples': len(rows), 'duration_s': sum(durations),
            'cpu_mean_percent': sum(v * d for v, d in zip(cpu, durations)) / sum(durations),
            'cpu_p95_percent': percentile(cpu, .95), 'cpu_peak_percent': max(cpu),
            'rss_mean_mib': statistics.mean(rss), 'rss_peak_mib': max(rss), 'rss_end_mib': rss[-1],
            'footprint_mean_mib': statistics.mean(footprint), 'footprint_peak_mib': max(footprint),
            'footprint_end_mib': footprint[-1]}

def read_status(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def wait_json(path, process, timeout):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if process.poll() is not None:
            raise RuntimeError('Child exited before creating ' + str(path))
        status = read_status(path)
        if status:
            return status
        time.sleep(.1)
    raise RuntimeError('Timed out waiting for ' + str(path))

def sha256(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4 * MIB), b''):
            result.update(block)
    return result.hexdigest()

def macho_content_sha256(path):
    """Hash all Mach-O bytes before the embedded signature, normalizing only
    signature-placement fields and __LINKEDIT size bookkeeping changed by codesign.
    All code, data, Swift metadata, symbols, and binding tables remain covered.
    """
    data = bytearray(path.read_bytes())
    if len(data) < 32 or struct.unpack_from('<I', data)[0] != 0xFEEDFACF:
        raise RuntimeError('Expected a thin little-endian 64-bit Mach-O executable')
    count = struct.unpack_from('<I', data, 16)[0]
    position = 32
    signature_offset = None
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, position)
        if size < 8 or position + size > len(data):
            raise RuntimeError('Malformed Mach-O load command')
        if command == 0x1D:  # LC_CODE_SIGNATURE
            signature_offset, signature_size = struct.unpack_from('<II', data, position + 8)
            if signature_offset + signature_size > len(data):
                raise RuntimeError('Embedded signature lies outside the Mach-O file')
            data[position + 8:position + 16] = bytes(8)
        elif command == 0x19 and data[position + 8:position + 24].split(b'\0')[0] == b'__LINKEDIT':
            data[position + 32:position + 40] = bytes(8)  # vmsize includes signature pages
            data[position + 48:position + 56] = bytes(8)  # filesize includes signature bytes
        position += size
    if signature_offset is None or signature_offset < position:
        raise RuntimeError('No valid embedded code-signature range')
    return hashlib.sha256(data[:signature_offset]).hexdigest()

def compile_seeder(output):
    output.parent.mkdir(parents=True, exist_ok=True)
    command = ['clang++', '-std=c++17', '-O2', '-fobjc-arc', '-mmacosx-version-min=27.0',
               '-DTORRENT_ABI_VERSION=2', '-DTORRENT_USE_RTC=0', '-DTORRENT_USE_LIBCRYPTO=1',
               '-DTORRENT_USE_OPENSSL=1', '-DTORRENT_SSL_PEERS=1', '-I' + str(ROOT / 'Vendor/include'),
               str(ROOT / 'Tests/BenchmarkSeeder.mm'), '-L' + str(ROOT / 'Vendor/lib'),
               '-ltorrent-rasterbar', '-lssl', '-lcrypto', '-framework', 'Foundation',
               '-framework', 'Security', '-framework', 'SystemConfiguration', '-o', str(output)]
    subprocess.run(command, check=True)

def markdown(result):
    labels = [('idle', 'Простой, нет задач'), ('active', 'Локальная загрузка, вкладка пиров'),
              ('retained', 'После загрузки, задача на паузе, вкладка логов')]
    lines = ['# TorrentFlow 0.2.0 — CPU и память', '',
             'Измерен настоящий Release-процесс GUI TorrentFlow, а не отдельный тест движка. '
             'macOS %s, %s; %s. CPU 100%% соответствует одному ядру.' %
             (result['environment']['macos'], result['environment']['machine'], result['environment']['hardware']), '',
             '| Сценарий | Время, с | CPU среднее | CPU p95 | CPU пик | RSS среднее, МиБ | RSS пик, МиБ | Footprint пик, МиБ |',
             '|---|---:|---:|---:|---:|---:|---:|---:|']
    for phase, label in labels:
        s = result['summary'][phase]
        lines.append('| %s | %.1f | %.2f%% | %.2f%% | %.2f%% | %.1f | %.1f | %.1f |' %
                     (label, s['duration_s'], s['cpu_mean_percent'], s['cpu_p95_percent'],
                      s['cpu_peak_percent'], s['rss_mean_mib'], s['rss_peak_mib'], s['footprint_peak_mib']))
    lines += ['', '## Методика', '',
              '- Сэмплы каждые 0,5 с через macOS `proc_pidinfo(PROC_PIDTASKINFO)`: суммарное процессорное время user + system переводится из Mach ticks в наносекунды через `mach_timebase_info`; резидентная память RSS. `proc_pid_rusage` даёт отдельный physical footprint.',
              '- До начала измерения приложение проходит штатный запуск, минимум 2 секунды прогрева и подтверждение видимости окна. '
              'В каждой фазе учитывается только PID приложения; локальный сид и скрипт измерения — отдельные процессы.',
              '- Передача: %d МиБ, локальный TCP-пир, ограничение класса локальных пиров сида 8 МиБ/с, настоящий magnet с получением метаданных и подтверждением выбора. '
              'Во время активной загрузки открыт нижний инспектор пиров. После завершения задача приостановлена, открыты логи.' % result['fixture']['size_mib'],
              '- DHT/LSD/UPnP в изолированном тесте выключены. У копии приложения отдельный Bundle ID `com.zel0th.TorrentFlow.Performance`, код и данные Mach-O и ресурсы совпадают с Release. Переподпись меняет встроенную подпись, поэтому полные SHA-256 Release и QA различаются; оба хеша и общий хеш содержимого Mach-O сохранены в JSON. Проверка нормализует только встроенную подпись, её служебные поля и размеры `__LINKEDIT`. Рабочая конфигурация и папки пользователя не менялись. '
              'Тестовые данные находятся в собственном временном каталоге.',
              '- Загруженный файл проверен SHA-256: `%s`.' % result['validation']['download_sha256'],
              '- Полный набор сэмплов и сведения о бинарном файле: `Performance-0.2.0.json`.', '',
              '## Границы результата', '',
              'Это один локальный замер на данном Mac: один торрент и один пир, без интернет-трекеров и VPN. '
              'Он проверяет стоимость интерфейса, обмена данными и инспектора, но не заменяет долговременный нагрузочный тест '
              'на сотнях задач и тысячах пиров. RSS включает отображённые страницы файлов; physical footprint и RSS имеют разные определения. '
              'Пиковый CPU — максимум интервала 0,5 с, а не мгновенное значение.', '']
    return '\n'.join(lines)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, default=ROOT / 'build/TorrentFlow.app')
    parser.add_argument('--duration', type=float, default=30)
    parser.add_argument('--size-mib', type=int, default=256)
    parser.add_argument('--output', type=Path, default=ROOT / 'Documentation/Performance-0.2.0.json')
    parser.add_argument('--compile-only', action='store_true')
    parser.add_argument('--await-visible', action='store_true', help='Wait for benchmark-visible control file after GUI appears')
    parser.add_argument('--keep-fixture', action='store_true', help='Keep generated payload files after a successful run')
    options = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('This benchmark requires macOS libproc')
    binary = options.app / 'Contents/MacOS/TorrentFlow' if options.app.suffix == '.app' else options.app
    seeder_binary = Path(tempfile.gettempdir()) / 'torrentflow-performance-tools/benchmark-seeder'
    compile_seeder(seeder_binary)
    if options.compile_only:
        print(seeder_binary)
        return
    if not binary.exists():
        parser.error('Build the final Release app before running the benchmark: ' + str(binary))
    if options.app.suffix == '.app':
        with (options.app / 'Contents/Info.plist').open('rb') as stream:
            version = plistlib.load(stream).get('CFBundleShortVersionString', '')
        if version != '0.2.0':
            parser.error('Expected the final 0.2.0 build, found ' + version)
    root = Path(tempfile.mkdtemp(prefix='torrentflow-performance-'))
    print('Benchmark root: ' + str(root), flush=True)
    source_binary = binary
    if options.app.suffix == '.app':
        qa_app = root / 'TorrentFlow Performance.app'
        def copy_bytes(source, target):
            shutil.copyfile(source, target)
            os.chmod(target, stat.S_IMODE(os.stat(source).st_mode))
            return target
        shutil.copytree(options.app, qa_app, copy_function=copy_bytes)
        subprocess.run(['/usr/bin/xattr', '-cr', str(qa_app)], check=True)
        info_path = qa_app / 'Contents/Info.plist'
        with info_path.open('rb') as stream:
            info = plistlib.load(stream)
        info['CFBundleIdentifier'] = 'com.zel0th.TorrentFlow.Performance'
        with info_path.open('wb') as stream:
            plistlib.dump(info, stream, sort_keys=False)
        binary = qa_app / 'Contents/MacOS/TorrentFlow'
        if sha256(binary) != sha256(source_binary):
            raise RuntimeError('QA executable copy differs before re-signing')
        source_content_hash = macho_content_sha256(source_binary)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(qa_app)], check=True)
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(qa_app)], check=True)
        binary = qa_app / 'Contents/MacOS/TorrentFlow'
        if macho_content_sha256(binary) != source_content_hash:
            raise RuntimeError('QA executable runtime content differs after re-signing')
        print('QA_APP ' + str(qa_app), flush=True)
    seeder_log = (root / 'seeder.log').open('w')
    app_log = (root / 'app.log').open('w')
    seeder = subprocess.Popen([str(seeder_binary), str(root), str(options.size_mib)], stdout=seeder_log, stderr=subprocess.STDOUT)
    app = None
    samples = []
    successful = False
    try:
        fixture = wait_json(root / 'fixture.json', seeder, 60)
        environment = os.environ.copy()
        environment.update({'TORRENTFLOW_STATE_ROOT': str(root / 'state'), 'TORRENTFLOW_PERF_ROOT': str(root),
                            'TORRENTFLOW_PERF_FIXTURE': str(root / 'fixture.json'),
                            'TORRENTFLOW_PERF_DESTINATION': str(root / 'download'),
                            'TORRENTFLOW_PERF_PORT': str(55000 + os.getpid() % 5000)})
        app = subprocess.Popen([str(binary)], env=environment, stdout=app_log, stderr=subprocess.STDOUT)
        sampler = Sampler(app.pid)
        print('GUI_PID ' + str(app.pid), flush=True)
        app_status_path = root / 'app-status.json'
        readiness = time.monotonic() + 30
        while time.monotonic() < readiness:
            state = read_status(app_status_path)
            if state.get('phase') == 'idle-ready':
                break
            if app.poll() is not None:
                raise RuntimeError('Application exited on startup; see ' + str(root / 'app.log'))
            if state.get('phase') == 'error':
                raise RuntimeError(state.get('error'))
            time.sleep(.1)
        else:
            raise RuntimeError('Application performance hook did not become ready')
        if options.await_visible:
            print('WAIT_VISIBLE ' + str(root / 'benchmark-visible'), flush=True)
            visible_deadline = time.monotonic() + 600
            while not (root / 'benchmark-visible').exists():
                if time.monotonic() >= visible_deadline or app.poll() is not None:
                    raise RuntimeError('Timed out waiting for GUI visibility acknowledgement')
                time.sleep(.25)
        print('PHASE idle', flush=True)
        sampler.sample('idle')
        deadline = time.monotonic() + options.duration
        while time.monotonic() < deadline:
            time.sleep(.5)
            samples.append(sampler.sample('idle'))
        (root / 'begin-transfer').touch()
        print('PHASE magnet metadata (outside timing)', flush=True)
        transfer_deadline = time.monotonic() + 170
        active_start = None
        completed_state = None
        while time.monotonic() < transfer_deadline:
            if app.poll() is not None:
                raise RuntimeError('Application exited during transfer')
            state = read_status(app_status_path)
            phase = state.get('phase')
            if phase == 'error':
                raise RuntimeError(state.get('error'))
            if phase == 'transferring':
                if active_start is None:
                    active_start = time.monotonic()
                    sampler.sample('active')
                    print('PHASE active', flush=True)
                else:
                    samples.append(sampler.sample('active'))
            elif phase == 'completed':
                if active_start is not None:
                    samples.append(sampler.sample('active'))
                completed_state = state
                break
            time.sleep(.5)
        if active_start is None or completed_state is None:
            raise RuntimeError('Payload transfer did not complete')
        active_duration = time.monotonic() - active_start
        if active_duration < options.duration * .75:
            raise RuntimeError('Active transfer too short for representative sampling: %.1f s' % active_duration)
        print('PHASE retained', flush=True)
        sampler.sample('retained')
        deadline = time.monotonic() + options.duration
        while time.monotonic() < deadline:
            time.sleep(.5)
            samples.append(sampler.sample('retained'))
        destination = root / 'download' / fixture['file']
        original = root / 'seed' / fixture['file']
        downloaded_sha = sha256(destination)
        assert downloaded_sha == sha256(original), 'Downloaded data SHA-256 mismatch'
        assert destination.stat().st_size == fixture['size'], 'Downloaded byte count mismatch'
        assert completed_state['done'] == fixture['size'], 'Application reported incomplete payload'
        environment_info = {'macos': platform.mac_ver()[0], 'machine': platform.machine(),
                            'hardware': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
                            'app_sha256': sha256(source_binary), 'qa_app_sha256': sha256(binary), 'macho_content_sha256': macho_content_sha256(binary), 'release_macho_content_sha256': macho_content_sha256(source_binary), 'signature_only_changes_verified': True, 'app_binary': str(source_binary), 'qa_app_binary': str(binary), 'qa_bundle_identifier': 'com.zel0th.TorrentFlow.Performance', 'app_pid': app.pid,
                            'sample_interval_s': .5, 'mach_timebase': {'numer': sampler.timebase_numer, 'denom': sampler.timebase_denom}, 'cpu_normalization': '100 percent = one CPU core',
                            'measurement_time_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
        result = {'environment': environment_info, 'fixture': {'size_mib': options.size_mib, 'bytes': fixture['size'], 'transport': 'loopback TCP', 'rate_limit_kib_per_s': 8192},
                  'summary': {phase: summary(samples, phase) for phase in ('idle', 'active', 'retained')},
                  'validation': {'download_sha256': downloaded_sha, 'reported_done_bytes': completed_state['done'], 'exact_size': destination.stat().st_size},
                  'samples': samples, 'temporary_root': str(root)}
        options.output.parent.mkdir(parents=True, exist_ok=True)
        options.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        options.output.with_suffix('.md').write_text(markdown(result))
        print(json.dumps(result['summary'], ensure_ascii=False, indent=2), flush=True)
        print('REPORT ' + str(options.output), flush=True)
        successful = True
        (root / 'finish').touch()
        try:
            app.wait(10)
        except subprocess.TimeoutExpired:
            app.terminate()
            app.wait(5)
    finally:
        (root / 'stop-seeder').touch()
        for child in (app, seeder):
            if child and child.poll() is None:
                try:
                    child.wait(4)
                except subprocess.TimeoutExpired:
                    child.terminate()
                    try:
                        child.wait(4)
                    except subprocess.TimeoutExpired:
                        child.kill()
        seeder_log.close()
        app_log.close()
        if successful and not options.keep_fixture:
            # These exact directories were created under this run's mkdtemp root.
            # Never remove the app bundle, logs, or any caller-supplied destination.
            shutil.rmtree(root / 'seed', ignore_errors=True)
            shutil.rmtree(root / 'download', ignore_errors=True)

if __name__ == '__main__':
    main()
