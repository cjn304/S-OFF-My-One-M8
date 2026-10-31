/* Diagnostic build: resolves the regulator, walks the consumer list and prints
 * what it found, but never touches the rail.  Load this one first. */
#define STAGE 3
#include "pwrsq_impl.h"
