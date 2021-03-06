#include <FL/Fl_PNG_Image.H>
#include <FL/Fl_JPEG_Image.H>
#include <FL/Fl_PNM_Image.H>
#include <FL/filename.H>
#include "cutil.h"
#include <complex>
#include "symbol.h"
#include "math_util.h"
#include "recfilter.h"
#include "effects.h"
#include "image_util.h"

#define USE_LAUNCH_BOUNDS 1

const int BW = 32, // cuda block width
          BH = 16, // cuda block height
          NB = 3;

template <class XFORM, class TO, int C, class FROM, int D>
__global__
#if USE_LAUNCH_BOUNDS
__launch_bounds__(BW*BH, NB)
#endif
void kernel(dimage_ptr<TO,C> out, dimage_ptr<const FROM,D> in)
{
    int tx = threadIdx.x, ty = threadIdx.y;

    int x = blockIdx.x*BW+tx, y = blockIdx.y*BH+ty;

    if(!in.is_inside(x,y))
        return;

    int idx = in.offset_at(x,y);
    in += idx;
    out += idx;

    XFORM xform;

    *out = xform(*in);
}

template <template<class,class> class XFORM, 
          class TO, int C, class FROM, int D>
void call_kernel(dimage_ptr<TO,C> out, dimage_ptr<const FROM,D> in)
{
    if(out.width() != in.width() || out.height() != in.height())
        throw std::runtime_error("Image dimensions don't match");

    dim3 bdim(BW,BH),
         gdim((in.width()+bdim.x-1)/bdim.x, (in.height()+bdim.y-1)/bdim.y);

    typedef XFORM<typename pixel_traits<TO,C>::pixel_type,
                  typename pixel_traits<FROM,D>::pixel_type> xform;

    kernel<xform><<<gdim, bdim>>>(out, in);
}

//{{{ conversion between pixel types --------------------------------------

template <class TO, class FROM, class EN=void>
struct convert_xform
{
    __device__ TO operator()(const FROM &p) const
    {
        return pixel_traits<TO>::make_pixel(p);
    }
};

template <class TO, class FROM>
struct convert_xform<TO,FROM,
    typename enable_if<pixel_traits<FROM>::is_integral && 
                      !pixel_traits<TO>::is_integral>::type>
{
    __device__ TO operator()(const FROM &p) const
    {
        return pixel_traits<TO>::make_pixel(p)/255.0f;
    }
};

template <class TO, class FROM>
struct convert_xform<TO,FROM,
    typename enable_if<!pixel_traits<FROM>::is_integral && 
                       pixel_traits<TO>::is_integral>::type>
{
    __device__ TO operator()(const FROM &p) const
    {
        return pixel_traits<TO>::make_pixel(saturate(p)*255.0f);
    }
};

template <class TO, class FROM>
struct convert_xform2 : convert_xform<TO,FROM> {};

template <class TO, int C, class FROM, int D>
void convert(dimage_ptr<TO,C> out, dimage_ptr<const FROM,D> in)
{
    call_kernel<convert_xform2>(out, in);
}

template void convert(dimage_ptr<float3> out, dimage_ptr<const float,3> in);
template void convert(dimage_ptr<uchar3> out, dimage_ptr<const float,3> in);

template void convert(dimage_ptr<float3> out, dimage_ptr<const uchar3> in);

template void convert(dimage_ptr<float,3> out, dimage_ptr<const float3> in);
template void convert(dimage_ptr<float,3> out, dimage_ptr<const uchar3> in);

template void convert(dimage_ptr<float3> out, dimage_ptr<const float> in);
template void convert(dimage_ptr<float,3> out, dimage_ptr<const float> in);
template void convert(dimage_ptr<uchar3> out, dimage_ptr<const float> in);
/*}}}*/

//{{{ lrgb2srgb ------------------------------------------------------------

template <class TO, class FROM>
struct lrgb2srgb_xform
{
    __device__ TO operator()(const FROM &p) const
    {
        return lrgb2srgb(p);
    }
};

template <class TO, int C, class FROM, int D>
void lrgb2srgb(dimage_ptr<TO,C> out, dimage_ptr<const FROM,D> in)
{
    call_kernel<lrgb2srgb_xform>(out, in);
}

template void lrgb2srgb(dimage_ptr<float3> out, dimage_ptr<const float3> in);
template void lrgb2srgb(dimage_ptr<float3> out, dimage_ptr<const float,3> in);
template void lrgb2srgb(dimage_ptr<float,3> out, dimage_ptr<const float,3> in);
template void lrgb2srgb(dimage_ptr<float> out, dimage_ptr<const float> in);
/*}}}*/

//{{{ grayscale ------------------------------------------------------------

template <class FROM, class EN=void>
struct grayscale_xform_base
{
    __device__ float operator()(const FROM &p) const
    {
        return grayscale(p);
    }
};

template <class FROM>
struct grayscale_xform_base<FROM,
    typename enable_if<pixel_traits<FROM>::is_integral>::type>
{
    __device__ float operator()(const FROM &p) const
    {
        return grayscale(make_float3(p)/255.0f);
    }
};

template <class TO, class FROM>
struct grayscale_xform;

template <class FROM>
struct grayscale_xform<float,FROM> : grayscale_xform_base<FROM> {};

template <class FROM, int D>
void grayscale(dimage_ptr<float> out, dimage_ptr<const FROM,D> in)
{
    call_kernel<grayscale_xform>(out, in);
}

template void grayscale(dimage_ptr<float> out, dimage_ptr<const uchar3> in);
template void grayscale(dimage_ptr<float> out, dimage_ptr<const float3> in);
template void grayscale(dimage_ptr<float> out, dimage_ptr<const float,3> in);
/*}}}*/

//{{{ luminance ------------------------------------------------------------

template <class TO, class FROM> struct luminance_xform;

template <class FROM>
struct luminance_xform<float,FROM>
{
    __device__ float operator()(const FROM &p) const
    {
        return luminance(p);
    }
};

template <class FROM, int D>
void luminance(dimage_ptr<float> out, dimage_ptr<const FROM,D> in)
{
    call_kernel<luminance_xform>(out, in);
}

template void luminance(dimage_ptr<float> out, dimage_ptr<const float3> in);
template void luminance(dimage_ptr<float> out, dimage_ptr<const float,3> in);
template<> void luminance(dimage_ptr<float> out, dimage_ptr<const float> in)
{
    out = in;
}

/*}}}*/

//{{{ convolution ------------------------------------------------------------

__constant__ float c_conv_kernel[20]; // max kernel diameter == 20

template<int R, class T, class U>
__device__
void load_convolve_rows(T *s_in, cudaTextureObject_t tex, int tx, U tu, U tv) /*{{{*/
{
    typedef pixel_traits<T> pix_traits;

    // load middle data
    s_in[R + tx] = pix_traits::make_pixel(tex2D<T>(tex, tu, tv ));

    // load left and right data
    if(R <= BW/2) 
    {
        if(tx < R) 
            s_in[tx] = pix_traits::make_pixel(tex2D<T>(tex, tu - R, tv));
        else if(tx < R*2) 
            s_in[BW+tx] = pix_traits::make_pixel(tex2D<T>(tex, tu - R+BW, tv));
    } 
    else if(R <= BW) 
    {
        if(tx < R) 
        {
            s_in[tx] = pix_traits::make_pixel(tex2D<T>(tex, tu - R, tv));
            s_in[R+BW + tx] = pix_traits::make_pixel(tex2D<T>(tex, tu + BW, tv));
        }
    } 
    else 
    {
#pragma unroll
        for (int i = 0; i < (R+BW-1)/BW; ++i) 
        {
            int wx = i*BW+tx;
            if( wx < R) 
            {
                s_in[wx] = pix_traits::make_pixel(tex2D<T>(tex, tu - R + i*BW, tv));
                s_in[R+BW + wx] = pix_traits::make_pixel(tex2D<T>(tex, tu + BW + i*BW, tv));
            }
        }
    }

    // convolve row
    T s = pix_traits::make_pixel(0.f);
    for (int k = -R; k <= R; ++k) 
        s += s_in[R + tx + k] * c_conv_kernel[k + R];

    s_in[R + tx] = s;
}/*}}}*/

template<int R,class T,int C>
__global__ __launch_bounds__(BW*BH, NB)
void convolution_kernel(dimage_ptr<T,C> out, cudaTextureObject_t tex,float inv_norm,/*{{{*/
                        int scale)
{
    int tx = threadIdx.x, ty = threadIdx.y;
    int x = blockIdx.x*BW+tx, y = blockIdx.y*BH+ty;

    typedef typename pixel_traits<T,C>::pixel_type pixel_type;
    typedef pixel_traits<pixel_type> pix_traits;


    float tu = x + .5f, tv = y + .5f;
    __shared__ pixel_type s_inblock[BH + R*2][BW + R*2];

    // load middle data
    load_convolve_rows<R>( &s_inblock[R + ty][0], tex, tx, tu, tv);

    // load upper and lower data
    if(R <= BH/2) 
    {
        if(ty < R) 
            load_convolve_rows<R>(&s_inblock[ty][0], tex, tx, tu, tv - R);
        else if(ty < R*2) 
            load_convolve_rows<R>(&s_inblock[BH + ty][0], tex, tx, tu, tv - R + BH);
    } 
    else if(R <= BH) 
    {
        if(ty < R) 
        {
            load_convolve_rows<R>(&s_inblock[ty][0], tex, tx, tu, tv - R);
            load_convolve_rows<R>(&s_inblock[R + BH + ty][0], tex, tx, tu, tv + BH);
        }
    } 
    else 
    {
        for (int i = 0; i < (R+BH-1)/BH; ++i) 
        {
            int wy = i*BH+ty;
            if( wy < R ) 
            {
                load_convolve_rows<R>(&s_inblock[wy][0], tex, tx, tu, tv - R + i*BH);
                load_convolve_rows<R>(&s_inblock[R + BH + wy][0], tex, tx, tu, tv + BH + i*BH);
            }
        }
    }

    __syncthreads();

    tx *= scale;
    ty *= scale;

    if(tx >= BW || ty >= BH)
        return;

    x = (blockIdx.x*BW)/scale + threadIdx.x;
    y = (blockIdx.y*BH)/scale + threadIdx.y;

    if(!out.is_inside(x,y))
        return;

    out += out.offset_at(x,y);

    // convolve cols
    pixel_type s = pixel_traits<T,C>::make_pixel(0.f);
#pragma unroll
    for (int k = -R; k <= R; ++k)
        s += s_inblock[R + ty + k][R + tx] * c_conv_kernel[k + R];
    *out = s*inv_norm;
}/*}}}*/

template <class T, int C, class U, int D, int R>
void convolve(dimage_ptr<T,C> out, dimage_ptr<const U,D> in,/*{{{*/
              const array<float,R> &kernel, int scale)
{
    gpu::copy_to_symbol(c_conv_kernel,kernel);

    typedef typename pixel_traits<U>::texel_type texel_type;

    cudaArray *a_in;
    cudaChannelFormatDesc ccd 
        = cudaCreateChannelDesc<texel_type>();

    cudaMallocArray(&a_in, &ccd, in.width(), in.height());

    struct cudaResourceDesc resDesc;
    memset(&resDesc, 0, sizeof(resDesc));
    resDesc.resType = cudaResourceTypeArray;
    resDesc.res.array.array = a_in;

    struct cudaTextureDesc texDesc;
    memset(&texDesc, 0, sizeof(texDesc));
    texDesc.addressMode[0] = texDesc.addressMode[1] = cudaAddressModeMirror;
    texDesc.filterMode = cudaFilterModePoint;
    texDesc.readMode = cudaReadModeElementType;
    texDesc.normalizedCoords = 0;

    dim3 bdim(BW,BH),
         gdim((in.width()+bdim.x-1)/bdim.x, (in.height()+bdim.y-1)/bdim.y);

    float norm=0;
    for(int i=0; i<kernel.size(); ++i)
        norm += kernel[i];

    cudaTextureObject_t texObj = 0;
    cudaCreateTextureObject(&texObj, &resDesc, &texDesc, NULL);

    for(int c=0; c<D; ++c)
    {
        cudaMemcpy2DToArray(a_in, 0, 0, in[c], 
                            in.rowstride()*sizeof(texel_type),
                            in.width()*sizeof(texel_type), in.height(),
                            cudaMemcpyDeviceToDevice);
        if(D==1)
            convolution_kernel<R><<<gdim, bdim>>>(out,texObj,1/(norm*norm), scale);
        else
            convolution_kernel<R><<<gdim, bdim>>>(out[c],texObj,1/(norm*norm), scale);
    }
    cudaDestroyTextureObject(texObj);
    cudaFreeArray(a_in);
}/*}}}*/

template void convolve(dimage_ptr<float,1> out, dimage_ptr<const float,1> in, 
                       const array<float,8> &kernel, int);

// lower sm doesn't have enough shared memory for RGB convolution
#if USE_SM>=20

template void convolve(dimage_ptr<float,3> out, dimage_ptr<const float3,1> in, 
                       const array<float,8> &kernel, int);

template void convolve(dimage_ptr<float3,1> out, dimage_ptr<const float3,1> in, 
                       const array<float,8> &kernel, int);


template void convolve(dimage_ptr<float,3> out, dimage_ptr<const float,3> in, 
                       const array<float,8> &kernel, int);
#endif
/*}}}*/

//{{{ I/O ------------------------------------------------------------

void load_image(const std::string &fname, std::vector<uchar4> *data,
                int *width, int *height)
{
    // Reads 'fname' into an Fl_Image
    Fl_Image *img;

    std::string FNAME = fname;
    strupr(const_cast<char *>(FNAME.data()));

    if(fl_filename_match(FNAME.c_str(),"*.PNG"))
        img = new Fl_PNG_Image(fname.c_str());
    else if(fl_filename_match(FNAME.c_str(),"*.JPG"))
        img = new Fl_JPEG_Image(fname.c_str());
    else if(fl_filename_match(FNAME.c_str(),"*.{PNM,PBM,PGM,PPM}"))
        img = new Fl_PNM_Image(fname.c_str());
    else
        throw std::runtime_error("Image type not supported");

    if(img->w()==0 || img->h()==0)
        throw std::runtime_error("Error loading image");

    if(width)
        *width = img->w();

    if(height)
        *height = img->h();

    // creates an RGBA array out of Fl_Image internal image representation
    if(data != NULL)
    {
        data->clear();
        data->reserve(img->w()*img->h());

        int irow = img->w()*img->d()+img->ld();
        unsigned char *currow = (unsigned char *)img->data()[0];

        // grayscale?
        if(img->d() < 3)
        {
            for(int i=0; i<img->h(); ++i, currow += irow)
            {
                for(int j=0; j<img->w(); ++j)
                {
                    int p = j*img->d();

                    uchar4 outp;
                    outp.x = outp.y = outp.z = currow[p];

                    // has alpha channel?
                    if(img->d() > 1)
                        outp.w = currow[p+1];
                    else
                        outp.w = 255;

                    data->push_back(outp);
                }
            }
        }
        // full RGB
        else
        {
            for(int i=0; i<img->h(); ++i, currow += irow)
            {
                for(int j=0; j<img->w(); ++j)
                {
                    int p = j*img->d();

                    uchar4 outp;
                    outp.x = currow[p];
                    outp.y = currow[p+1];
                    outp.z = currow[p+2];

                    // has alpha channel?
                    if(img->d() > 3)
                        outp.w = currow[p+3];
                    else
                        outp.w = 255;

                    data->push_back(outp);
                }
            }
        }
    }
}

#if 0
void save_image(const std::string &fname, const std::vector<uchar4> &data,
                 int width, int height)
{
    if(fl_filename_match(strupr(fname).c_str(),"*.PPM"))
        throw std::runtime_error("We only support PPM output image format");

    if(!cutSavePPM4ub(fname.c_str(), (unsigned char *)&data[0], width, height))
        throw std::runtime_error("Error saving output image");
}

void save_image(const std::string &fname, const std::vector<unsigned char> &data,
                 int width, int height)
{
    if(fl_filename_match(strupr(fname).c_str(),"*.PGM"))
        throw std::runtime_error("We only support PGM output image format");

    if(!cutSavePGMub(fname.c_str(), (unsigned char *)&data[0], width, height))
        throw std::runtime_error("Error saving output image");
}

void save_image(const std::string &fname, const std::vector<float> &data,
                 int width, int height)
{
    if(fl_filename_match(strupr(fname).c_str(),"*.PGM"))
        throw std::runtime_error("We only support PGM output image format");

    if(!cutSavePGMf(fname.c_str(), (float *)&data[0], width, height))
        throw std::runtime_error("Error saving output image");
}

template<>
void save_image(const std::string &fname, dimage_ptr<const uchar3> img)
{
    std::vector<uchar4> data;
    img.copy_to_host(data);

    save_image(fname, data, img.width(), img.height());
}

template<>
void save_image(const std::string &fname, dimage_ptr<const unsigned char> img)
{
    std::vector<unsigned char> data;
    img.copy_to_host(data);

    save_image(fname, data, img.width(), img.height());
}

template<>
void save_image(const std::string &fname, dimage_ptr<const float> img)
{
    std::vector<float> data;
    img.copy_to_host(data);

    save_image(fname, data, img.width(), img.height());
}

template <class T, int C>
void save_image(const std::string &fname, dimage_ptr<const T,C> img)
{
    dimage<typename make_cuda_type<unsigned char,pixel_traits<T,C>::components>::type> aux;
    aux.resize(img.width(), img.height());
    convert(&aux, img);
    save_image(fname, &aux);
}

template void save_image(const std::string &fname, dimage_ptr<const float> img);
template void save_image(const std::string &fname, dimage_ptr<const float3> img);
template void save_image(const std::string &fname, dimage_ptr<const float,3> img);

template void save_image(const std::string &fname, dimage_ptr<const unsigned char> img);
template void save_image(const std::string &fname, dimage_ptr<const uchar3> img);
template void save_image(const std::string &fname, dimage_ptr<const unsigned char,3> img);

#endif

/*}}}*/

//{{{ gaussian blur ---------------------------------------------------------

namespace
{
    typedef std::complex<double> dcomplex;
    const dcomplex d1(1.41650, 1.00829);
    const double d3(1.86543);

    double qs(double s) {
        return .00399341 + .4715161*s;
    }

    double ds(double d, double s) {
        return pow(d, 1.0/qs(s));
    }

    dcomplex ds(dcomplex d, double s)
    {
        double q = qs(s);
        return std::polar(pow(abs(d),1.0/q), arg(d)/q);
    }

    void gaussian_weights1(double s, Vector<float,2> &w)
    {
        double d = ds(d3, s);

        int sign;
        if(rec_op(1,1)==0)
            sign = -1;
        else
            sign = 1;

        w[0] = static_cast<float>(-(1.0-d)/d);
        w[1] = sign*static_cast<float>(1.0/d);
    }

    void gaussian_weights2(double s, Vector<float,3> &w)
    {
        dcomplex d = ds(d1, s);
        double n2 = abs(d);
        n2 *= n2;
        double re = real(d);

        int sign;
        if(rec_op(1,1)==0)
            sign = -1;
        else
            sign = 1;

        w[0] = static_cast<float>((1-2*re+n2)/n2);
        w[1] = sign*static_cast<float>(2*re/n2);
        w[2] = sign*static_cast<float>(-1/n2);
    }

}

struct gaussian_blur_plan
{
    gaussian_blur_plan() : plan1(NULL), plan2(NULL) {}
    ~gaussian_blur_plan()
    {
        free(plan1);
        free(plan2);
    }

    recfilter5_plan *plan1, *plan2;
};

gaussian_blur_plan *gaussian_blur_create_plan(int width, int height,
                                              int rowstride, float sigma)
{
    gaussian_blur_plan *plan = new gaussian_blur_plan();
    try
    {
        update_plan(plan, width, height, rowstride, sigma);

        return plan;
    }
    catch(...)
    {
        delete plan;
        throw;
    }
}

void free(gaussian_blur_plan *plan)
{
    delete plan;
}

void update_plan(gaussian_blur_plan *plan, int width, int height, 
                 int rowstride, float sigma)
{
    // TODO: must have strong exception guarantee!

    Vector<float,1+1> weights1;
    gaussian_weights1(sigma,weights1);

    if(plan->plan1 == NULL)
    {
        plan->plan1 = recfilter5_create_plan<1>(width, height, 
                                                rowstride, weights1);
    }
    else
        update_plan<1>(plan->plan1, width, height, rowstride, weights1);

    Vector<float,1+2> weights2;
    gaussian_weights2(sigma,weights2);

    if(plan->plan2 == NULL)
    {
        plan->plan2 = recfilter5_create_plan<2>(width, height, 
                                                rowstride, weights2);
    }
    else
        update_plan<2>(plan->plan2, width, height, rowstride, weights2);

}

template <int C>
void gaussian_blur(gaussian_blur_plan *plan, dimage_ptr<float, C> out, 
                   dimage_ptr<const float,C> in)
{
    assert(plan != NULL);

    for(int i=0; i<C; ++i)
        recfilter5(plan->plan1, out[i], in[i]);

    for(int i=0; i<C; ++i)
        recfilter5(plan->plan2, out[i]);
}

template
void gaussian_blur(gaussian_blur_plan *plan, dimage_ptr<float> out, 
                   dimage_ptr<const float> in);

template
void gaussian_blur(gaussian_blur_plan *plan, dimage_ptr<float,3> out, 
                   dimage_ptr<const float,3> in);

/*}}}*/
