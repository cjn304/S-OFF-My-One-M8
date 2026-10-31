/* Stage 1: cut VCC to the eMMC.  This is what clears the eMMC power-on write
 * protection that hboot armed at boot. */
#define STAGE 1
#include "pwrsq_impl.h"
