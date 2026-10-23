#ifndef GHOSTEDIT_HARPER_BRIDGE_H
#define GHOSTEDIT_HARPER_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

// Returns a JSON array. The caller owns the result and must free it below.
char *harper_lint(const char *text);
void harper_free_string(char *text);

#ifdef __cplusplus
}
#endif

#endif
