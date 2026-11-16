#ifndef CHROME_BROWSER_SOLARA_PIP_AC_PIP_GEOMETRY_H_
#define CHROME_BROWSER_SOLARA_PIP_AC_PIP_GEOMETRY_H_

#include <math.h>

typedef struct {
  double width;
  double height;
} ACPiPSize;

static inline double ACPiPAspect(double aspect, ACPiPSize fallback) {
  return isfinite(aspect) && aspect > 0 ? aspect : fallback.width / fallback.height;
}

static inline ACPiPSize ACPiPMinimumSize(double aspect, ACPiPSize baseline) {
  aspect = ACPiPAspect(aspect, baseline);
  const double long_aspect = aspect >= 1 ? aspect : 1 / aspect;
  const double short_side = fmax(fmin(baseline.width, baseline.height),
                                 sqrt(baseline.width * baseline.height / long_aspect));
  const double long_side = short_side * long_aspect;
  const ACPiPSize size = {aspect >= 1 ? long_side : short_side,
                          aspect >= 1 ? short_side : long_side};
  return size;
}

static inline ACPiPSize ACPiPMinimumSizeWithinMaximum(double aspect,
                                                      ACPiPSize baseline,
                                                      ACPiPSize maximum) {
  ACPiPSize size = ACPiPMinimumSize(aspect, baseline);
  if (maximum.width > 0 && maximum.height > 0) {
    const double scale = fmin(1, fmin(maximum.width / size.width,
                                    maximum.height / size.height));
    size.width *= scale;
    size.height *= scale;
  }
  return size;
}

static inline ACPiPSize ACPiPNativeMinimumSize(double aspect,
                                              ACPiPSize baseline,
                                              ACPiPSize maximum) {
  const ACPiPSize ideal = ACPiPMinimumSize(aspect, baseline);
  ACPiPSize size = ACPiPMinimumSizeWithinMaximum(aspect, baseline, maximum);
  const int constrained = size.width < ideal.width || size.height < ideal.height;
  size.width = fmax(1, constrained ? floor(size.width) : ceil(size.width));
  size.height = fmax(1, constrained ? floor(size.height) : ceil(size.height));
  if (maximum.width > 0 && maximum.height > 0) {
    size.width = fmin(size.width, maximum.width);
    size.height = fmin(size.height, maximum.height);
  }
  return size;
}

static inline ACPiPSize ACPiPRestoredSize(ACPiPSize remembered,
                                        double aspect,
                                        ACPiPSize minimum,
                                        ACPiPSize maximum) {
  aspect = ACPiPAspect(aspect, minimum);
  const double low = fmax(minimum.width, minimum.height * aspect);
  const double high = fmin(maximum.width, maximum.height * aspect);
  double width = low;
  if (isfinite(remembered.width) && remembered.width > 0 &&
      isfinite(remembered.height) && remembered.height > 0) {
    width = sqrt(remembered.width * remembered.height * aspect);
  }
  width = fmin(fmax(width, low), high);
  const ACPiPSize size = {width, width / aspect};
  return size;
}

#endif
