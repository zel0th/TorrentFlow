#ifndef TORRENTFLOW_BRIDGE_H
#define TORRENTFLOW_BRIDGE_H
#ifdef __cplusplus
extern "C" {
#endif
typedef void *TFEngine;
TFEngine tf_create(const char *state_directory, const char *draft_directory);
void tf_destroy(TFEngine engine);
const char *tf_version(void);
char *tf_stage(TFEngine engine, const char *source);
char *tf_snapshot(TFEngine engine);
char *tf_snapshot_scoped(TFEngine engine, const char *selected_identifier);
char *tf_details(TFEngine engine, const char *identifier);
char *tf_details_filtered(TFEngine engine, const char *identifier, int include_peers, int include_logs);
char *tf_clear_logs(TFEngine engine, const char *identifier);
char *tf_commit(TFEngine engine, const char *identifier, const char *destination,
                const int *priorities, int count, int start);
char *tf_commit_with_names(TFEngine engine, const char *identifier, const char *destination,
                const int *priorities, int count, int start, const char *json_names);
char *tf_add_trackers(TFEngine engine, const char *identifier, const char *json_urls);
char *tf_set_file_priority(TFEngine engine, const char *identifier, int index, int priority);
char *tf_command(TFEngine engine, const char *identifier, const char *command);
char *tf_priorities(TFEngine engine, const char *identifier, const int *priorities, int count);
char *tf_configure(TFEngine engine, const char *json);
char *tf_save(TFEngine engine);
char *tf_note(TFEngine engine, const char *message, const char *level);
void tf_free(char *string);
#ifdef __cplusplus
}
#endif
#endif
