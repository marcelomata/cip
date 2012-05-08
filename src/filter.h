#ifndef NLFILTER_FILTER_H
#define NLFILTER_FILTER_H

#include "dvector.h"
#include "config.h"

// number of samples per pixel
#define SAMPDIM 8

#define KS 4 // pre- and post-filter kernel support size

void init_blue_noise();

enum effect_type
{
    EFFECT_IDENTITY,
    EFFECT_POSTERIZE,
    EFFECT_SCALE,
    EFFECT_BIAS,
    EFFECT_ROOT,
    EFFECT_THRESHOLD,
    EFFECT_REPLACEMENT,
    EFFECT_LAPLACIAN,
    EFFECT_GRADIENT_EDGE_DETECTION
};

struct filter_operation
{
    effect_type type;

    union
    {
        // posterize
        int levels;

        // scale
        float scale;

        // bias
        float bias;

        // root
        float degree;

        // threshold
        float threshold;

        // replacement
        struct
        {
            float3 old_color, new_color, tau;
        };
    };
};


#if CUDA_SM >= 20
void filter(dvector<float> imgchan[3], int width, int height, int rowstride,
            const filter_operation &op);
#endif

void filter(dvector<float> &img, int width, int height, int rowstride,
            const filter_operation &op);

#endif
