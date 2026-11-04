#ifndef VEIL_CHAIN_CORE_H
#define VEIL_CHAIN_CORE_H
#include <stddef.h>
// Local-only JSON ABI. The archive contains no RPC wrapper or network transport.
char *veil_chain_execute(const char *request);
void veil_chain_free(char *response);
#endif
