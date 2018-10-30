#include "CUDACopy.h"

#include "ATen/ATen.h"
#include "ATen/Context.h"
#include "ATen/Copy.h"
#include "ATen/Dispatch.h"
#include "ATen/NativeFunctions.h"
#include "ATen/cuda/CUDAApplyUtils.cuh"
#include "ATen/cuda/CUDAContext.h"
#include "ATen/cuda/CUDAEvent.h"
#include "ATen/cuda/CUDAStream.h"

namespace {

using namespace at;
using namespace at::cuda;

// Copy operator for the pointwise apply kernel
template <typename dst_T, typename src_T>
struct CopyOp {
  static void apply(Tensor& dst, const Tensor& src) {
    CUDA_tensor_apply2<dst_T, src_T>(
        dst, src, [] __device__(dst_T & dst_val, const src_T& src_val) {
#if __CUDA_ARCH__ >= 350
          dst_val = static_cast<dst_T>(
              static_cast<inter_copy_type_t<dst_T>>(__ldg(&src_val)));
#else
          dst_val = static_cast<dst_T>(static_cast<inter_copy_type_t<dst_T>>(__ldg(src_val)));
#endif
        });
  }
};

// device-to-device copy, does type conversion
template <typename dst_T, typename src_T>
void copy_device_to_device(Tensor& dst, const Tensor& src) {
  auto numel = dst.numel();

  if (dst.dim() == 0) {
    // Zero-dim tensor; copy nothing
    return;
  }

  // We can memcpy the memory if:
  // -both tensors are contiguous; or,
  // -there is only one element to copy; or,
  // -FIXME: if both tensors have matching size and stride arrays, and no
  // holes within (in other words, there is some permutation that can be applied
  // to the size/strides such that the resulting tensor is
  // contiguous).
  // -AND: both tensors have the same type.
  bool same_type = std::is_same<dst_T, src_T>::value;
  bool memcpyEligible =
      ((src.is_contiguous() && dst.is_contiguous()) || (numel == 1)) &&
      same_type;

  int16_t src_device = src.get_device();
  int16_t dst_device = dst.get_device();

  // Try to enable p2p access. This also handles the case src_device ==
  // dst_device.
  bool p2pEnabled = THCState_getPeerToPeerAccess(
      globalContext().getTHCState(), src_device, dst_device);

  // We always perform the copy on the source device, using the
  // current stream on the source device.
  // If the copy is on the default stream, then we fully synchronize
  // both src and dst's default streams for completion of the
  // copy. We have to explicitly do this for non-contig copies.
  // This mimics the behavior of cross-device cudaMemcpyAsync on
  // the default stream.
  // If the copy is not on the default stream, then it is up to the
  // user to add needed synchronization on the dst device, since the
  // stream on the dst device that wishes to synchronize may not be
  // the same index as the one on the src device.
  CUDAStream copy_stream = getCurrentCUDAStream(src_device);
  if (src_device != dst_device && copy_stream == NULL) {
    // This is a cross-device copy on the default stream. We perform a
    // two-way barrier between both devices' default streams before
    // the copy. This ensures that any write-after-write and
    // write-after-read dependencies on the destination side are
    // handled, so that no one is operating on the dst memory when
    // we perform the copy.
    // src waits on dst barrier (src already waits on src)
    CUDAEvent dst_ready;
    DeviceGuard device_guard_dst{dst_device};
    dst_ready.record(getDefaultCUDAStream(dst_device));

    DeviceGuard device_guard_src{src_device};
    dst_ready.block(copy_stream);
  }

  DeviceGuard device_guard{src_device};

  if (memcpyEligible) {
    // Perform the copy
    AT_CUDA_CHECK(cudaMemcpyAsync(
        dst.data<dst_T>(),
        src.data<src_T>(),
        numel * sizeof(dst_T),
        cudaMemcpyDeviceToDevice,
        copy_stream));
  } else {
    // Non-contiguous copy or a type-conversion copy

    // We avoid creating temporary memory copies if possible.
    // If both src and dst are on the same device, or if they are on
    // different devices and p2p access is enabled, perform the copy
    // by a pointwise copy kernel.
    // Otherwise, we'll have to make contiguous (which will in fact
    // invoke copy() again), and then perform the copy.
    // FIXME: might want to consider only running the pointwise kernel
    // if both src and dst innermost dimensions are contiguous. If
    // they are not, then taking the hit of the memory allocation/free
    // might be worth it to avoid non-coalesced reads or writes.
    if (p2pEnabled) {
      CopyOp<dst_T, src_T>::apply(dst, src);
    } else {
      // GPUs can't access each other directly, but the tensors
      // involved are non-contiguous and/or are different types.

      // Make sure the src is contiguous and in the same type as dst
      Tensor src_contig;
      if (same_type) {
        src_contig = src.contiguous();
      } else {
        // Types are different
        // Copy into the new format, contiguous, on the source device
        src_contig = at::empty_like(dst);

        CopyOp<dst_T, src_T>::apply(dst, src);
      }

      // Make sure the dst is contiguous
      DeviceGuard device_guard_dst{dst_device};
      Tensor dst_contig = dst.contiguous();

      // Now, we are ready for a cross-device memcpy of contiguous
      // data, of the same layout and type
      DeviceGuard device_guard_src{src_device};

      AT_CUDA_CHECK(cudaMemcpyAsync(
          dst_contig.data<dst_T>(),
          src_contig.data<dst_T>(),
          numel * sizeof(dst_T),
          cudaMemcpyDeviceToDevice,
          copy_stream));

      if (!dst.is_contiguous()) {
        copy_device_to_device<dst_T, dst_T>(dst_contig, dst);
      }
    }
  }

  if (src_device != dst_device && copy_stream == NULL) {
    // dst waits on src barrier (dst already waits on dst). We cannot
    // operate on dst's copy until the copy is complete.

    // Still on src_device, record default stream event
    CUDAEvent src_ready;
    src_ready.record(copy_stream);

    DeviceGuard device_guard{dst_device};
    src_ready.block(getDefaultCUDAStream(dst_device));
  }

  AT_CUDA_CHECK(cudaGetLastError());
}

} // namespace

namespace at {
namespace cuda {

void copy_from_cpu(Tensor& dst, const Tensor& src) {
  Tensor dst_contig = dst.contiguous();
  Tensor src_contig = src.contiguous();

  CUDAStream stream = getCurrentCUDAStream();

  AT_DISPATCH_ALL_TYPES_AND_HALF(src.type(), "copy_from_cpu", [&]() {
    AT_CUDA_CHECK(cudaMemcpyAsync(
        dst_contig.data<scalar_t>(),
        src_contig.data<scalar_t>(),
        src.numel() * sizeof(scalar_t),
        cudaMemcpyHostToDevice,
        stream));
    AT_CUDA_CHECK(cudaStreamSynchronize(stream));
    copy_device_to_device<scalar_t, scalar_t>(dst, dst_contig);
  });
}

void copy_to_cpu(Tensor& dst, const Tensor& src) {
  Tensor dst_contig = dst.contiguous();
  Tensor src_contig = src.contiguous();

  DeviceGuard device_guard{static_cast<int16_t>(src.get_device())};
  CUDAStream stream = getCurrentCUDAStream();

  AT_DISPATCH_ALL_TYPES_AND_HALF(src.type(), "copy_to_cpu", [&]() {
    AT_CUDA_CHECK(cudaMemcpyAsync(
        dst_contig.data<scalar_t>(),
        src_contig.data<scalar_t>(),
        src.numel() * sizeof(scalar_t),
        cudaMemcpyDeviceToHost,
        stream));
    AT_CUDA_CHECK(cudaStreamSynchronize(stream));
    copy_cpu(dst, dst_contig);
  });
}

template <typename dst_T>
void copy_cuda(Tensor& dst, const Tensor& src) {
  AT_DISPATCH_ALL_TYPES_AND_HALF(src.type(), "copy_cuda", [&]() {
    if (dst.is_cuda() && src.is_cuda()) {
      copy_device_to_device<dst_T, scalar_t>(dst, src);
    } else if (dst.is_cuda()) {
      Tensor srcf = at::empty_like(src);
      copy_cpu(srcf, src);
      copy_from_cpu(dst, srcf);
    } else {
      Tensor srcf = at::empty_like(src);
      copy_device_to_device<dst_T, scalar_t>(srcf, src);
      copy_to_cpu(dst, srcf);
    }
  });
}

Tensor copy_cuda(Tensor& dst, const Tensor& src) {
  AT_DISPATCH_ALL_TYPES_AND_HALF(
      dst.type(), "copy_cuda", [&]() { copy_cuda<scalar_t>(dst, src); });
  return dst;
}

} // namespace cuda
} // namespace at