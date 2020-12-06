// ----------------------------------------------------------------------------
// -                        Open3D: www.open3d.org                            -
// ----------------------------------------------------------------------------
// The MIT License (MIT)
//
// Copyright (c) 2018 www.open3d.org
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.
// ----------------------------------------------------------------------------

#include "open3d/core/Dispatch.h"
#include "open3d/core/Dtype.h"
#include "open3d/core/MemoryManager.h"
#include "open3d/core/SizeVector.h"
#include "open3d/core/Tensor.h"
#include "open3d/core/hashmap/Hashmap.h"
#include "open3d/core/kernel/CUDALauncher.cuh"
#include "open3d/core/kernel/GeneralEW.h"
#include "open3d/core/kernel/GeneralEWMacros.h"
#include "open3d/core/kernel/GeneralIndexer.h"
#include "open3d/utility/Console.h"

namespace open3d {
namespace core {
namespace kernel {

void CUDAUnprojectKernel(const std::unordered_map<std::string, Tensor>& srcs,
                         std::unordered_map<std::string, Tensor>& dsts) {
    static std::vector<std::string> src_attrs = {
            "depth",
            "intrinsics",
            "depth_scale",
            "depth_max",
    };
    for (auto& k : src_attrs) {
        if (srcs.count(k) == 0) {
            utility::LogError(
                    "[CUDAUnprojectKernel] expected Tensor {} in srcs, but "
                    "did not receive",
                    k);
        }
    }

    // Input
    Tensor depth = srcs.at("depth").To(core::Dtype::Float32);
    Tensor intrinsics = srcs.at("intrinsics").To(core::Dtype::Float32);
    float depth_scale = srcs.at("depth_scale").Item<float>();
    float depth_max = srcs.at("depth_max").Item<float>();

    NDArrayIndexer depth_ndi(depth, 2);
    TransformIndexer ti(intrinsics);

    // Output
    Tensor vertex_map({depth_ndi.GetShape(0), depth_ndi.GetShape(1), 3},
                      core::Dtype::Float32, depth.GetDevice());
    NDArrayIndexer vertex_ndi(vertex_map, 2);

    // Workload
    int64_t n = depth_ndi.NumElements();

    CUDALauncher::LaunchGeneralKernel(
            n, [=] OPEN3D_HOST_DEVICE(int64_t workload_idx) {
                int64_t y, x;
                depth_ndi.WorkloadToCoord(workload_idx, &x, &y);

                float d = *static_cast<float*>(depth_ndi.GetDataPtrFromWorkload(
                                  workload_idx)) /
                          depth_scale;
                d = (d >= depth_max) ? 0 : d;

                float* vertex = static_cast<float*>(
                        vertex_ndi.GetDataPtrFromWorkload(workload_idx));

                ti.Unproject(static_cast<float>(x), static_cast<float>(y), d,
                             vertex, vertex + 1, vertex + 2);
            });

    dsts.emplace("vertex_map", vertex_map);
}

/// Dummy kernel launch: global hashmap calls
void CUDATSDFTouchKernel(const std::unordered_map<std::string, Tensor>& srcs,
                         std::unordered_map<std::string, Tensor>& dsts) {
    static std::vector<std::string> src_attrs = {
            "points",
            "voxel_size",
            "resolution",
    };

    for (auto& k : src_attrs) {
        if (srcs.count(k) == 0) {
            utility::LogError(
                    "[CUDATSDFTouchKernel] expected Tensor {} in srcs, but "
                    "did not receive",
                    k);
        }
    }

    Tensor pcd = srcs.at("points");
    float voxel_size = srcs.at("voxel_size").Item<float>();
    int64_t resolution = srcs.at("resolution").Item<int64_t>();
    Device device = pcd.GetDevice();

    float block_size = voxel_size * resolution;
    core::Tensor block_coordd = pcd / block_size;
    core::Tensor block_coordi = block_coordd.To(core::Dtype::Int64);
    core::Hashmap pcd_block_hashmap(
            block_coordi.GetShape()[0],
            core::Dtype(core::Dtype::DtypeCode::Object,
                        core::Dtype::Int64.ByteSize() * 3, "_hash_k"),
            core::Dtype::Int64, device);
    core::Tensor block_addrs, block_masks;
    pcd_block_hashmap.Activate(block_coordi, block_addrs, block_masks);

    // Activate in blocks
    core::Tensor block_coords = block_coordi.IndexGet({block_masks});
    int64_t block_count = block_coords.GetShape()[0];
    core::Tensor block_nb_coords({27, block_count, 3}, core::Dtype::Int64,
                                 device);

    /// 3x3 neighbor blocks, more aggressive sampling
    for (int nb = 0; nb < 27; ++nb) {
        int dz = nb / 9;
        int dy = (nb % 9) / 3;
        int dx = nb % 3;
        core::Tensor dt =
                core::Tensor(std::vector<int64_t>{dx - 1, dy - 1, dz - 1},
                             {1, 3}, core::Dtype::Int64, device);
        block_nb_coords[nb] = block_coords + dt;
    }

    dsts.emplace("block_coords", block_nb_coords.View({27 * block_count, 3}));
}

void CUDATSDFIntegrateKernel(
        const std::unordered_map<std::string, Tensor>& srcs,
        std::unordered_map<std::string, Tensor>& dsts) {
    // Decode input tensors
    static std::vector<std::string> src_attrs = {
            "depth",      "indices",    "block_keys",
            "intrinsics", "extrinsics", "resolution",
            "voxel_size", "sdf_trunc",  "depth_scale",
    };
    for (auto& k : src_attrs) {
        if (srcs.count(k) == 0) {
            utility::LogError(
                    "[CUDATSDFIntegrateKernel] expected Tensor {} in srcs, but "
                    "did not receive",
                    k);
        }
    }

    Tensor depth = srcs.at("depth").To(core::Dtype::Float32);
    Tensor indices = srcs.at("indices");
    Tensor block_keys = srcs.at("block_keys");
    Tensor block_values = dsts.at("block_values");

    // Transforms
    Tensor intrinsics = srcs.at("intrinsics").To(core::Dtype::Float32);
    Tensor extrinsics = srcs.at("extrinsics").To(core::Dtype::Float32);

    // Parameters
    int64_t resolution = srcs.at("resolution").Item<int64_t>();
    int64_t resolution3 = resolution * resolution * resolution;

    float voxel_size = srcs.at("voxel_size").Item<float>();
    float sdf_trunc = srcs.at("sdf_trunc").Item<float>();
    float depth_scale = srcs.at("depth_scale").Item<float>();

    // Shape / transform indexers, no data involved
    NDArrayIndexer voxel_indexer({resolution, resolution, resolution});
    TransformIndexer transform_indexer(intrinsics, extrinsics, voxel_size);

    // Real data indexer
    NDArrayIndexer image_indexer(depth, 2);
    NDArrayIndexer voxel_block_buffer_indexer(block_values, 4);

    // Plain arrays that does not require indexers
    int64_t* indices_ptr = static_cast<int64_t*>(indices.GetDataPtr());
    int64_t* block_keys_ptr = static_cast<int64_t*>(block_keys.GetDataPtr());

    int64_t n = indices.GetShape()[0] * resolution3;
    CUDALauncher::LaunchGeneralKernel(n, [=] OPEN3D_HOST_DEVICE(
                                                 int64_t workload_idx) {
        // Natural index (0, N) -> (block_idx, voxel_idx)
        int64_t block_idx = indices_ptr[workload_idx / resolution3];
        int64_t voxel_idx = workload_idx % resolution3;

        /// Coordinate transform
        // block_idx -> (x_block, y_block, z_block)
        int64_t xb = block_keys_ptr[block_idx * 3 + 0];
        int64_t yb = block_keys_ptr[block_idx * 3 + 1];
        int64_t zb = block_keys_ptr[block_idx * 3 + 2];

        // voxel_idx -> (x_voxel, y_voxel, z_voxel)
        int64_t xv, yv, zv;
        voxel_indexer.WorkloadToCoord(voxel_idx, &xv, &yv, &zv);

        // coordinate in world (in voxel)
        int64_t x = (xb * resolution + xv);
        int64_t y = (yb * resolution + yv);
        int64_t z = (zb * resolution + zv);

        // coordinate in camera (in voxel -> in meter)
        float xc, yc, zc, u, v;
        transform_indexer.RigidTransform(static_cast<float>(x),
                                         static_cast<float>(y),
                                         static_cast<float>(z), &xc, &yc, &zc);

        // coordinate in image (in pixel)
        transform_indexer.Project(xc, yc, zc, &u, &v);
        if (!image_indexer.InBoundary(u, v)) {
            return;
        }

        /// Associate image workload and compute SDF
        int64_t workload_image;
        image_indexer.CoordToWorkload(static_cast<int64_t>(u),
                                      static_cast<int64_t>(v), &workload_image);
        float depth =
                *static_cast<const float*>(
                        image_indexer.GetDataPtrFromWorkload(workload_image)) /
                depth_scale;
        float sdf = depth - zc;
        if (depth <= 0 || zc <= 0 || sdf < -sdf_trunc) {
            return;
        }
        sdf = sdf < sdf_trunc ? sdf : sdf_trunc;
        sdf /= sdf_trunc;

        /// Associate voxel workload and update TSDF/Weights
        int64_t workload_voxel;
        voxel_block_buffer_indexer.CoordToWorkload(xv, yv, zv, block_idx,
                                                   &workload_voxel);
        float* voxel_ptr = static_cast<float*>(
                voxel_block_buffer_indexer.GetDataPtrFromWorkload(
                        workload_voxel));

        float tsdf_sum = voxel_ptr[0];
        float weight_sum = voxel_ptr[1];
        voxel_ptr[0] = (weight_sum * tsdf_sum + sdf) / (weight_sum + 1);
        voxel_ptr[1] = weight_sum + 1;
    });
}

void CUDASurfaceExtractionKernel(
        const std::unordered_map<std::string, Tensor>& srcs,
        std::unordered_map<std::string, Tensor>& dsts) {
    // Decode input tensors
    static std::vector<std::string> src_attrs = {
            "indices",      "nb_indices", "nb_masks",   "block_keys",
            "block_values", "voxel_size", "resolution",
    };
    for (auto& k : src_attrs) {
        if (srcs.count(k) == 0) {
            utility::LogError(
                    "[CPUTSDFIntegrateKernel] expected Tensor {} in srcs, but "
                    "did not receive",
                    k);
        }
    }
    utility::LogInfo("surface extraction starts");

    Tensor indices = srcs.at("indices");
    Tensor nb_indices = srcs.at("nb_indices");
    Tensor nb_masks = srcs.at("nb_masks");
    Tensor block_keys = srcs.at("block_keys");
    Tensor block_values = srcs.at("block_values");

    // Parameters
    int64_t resolution = srcs.at("resolution").Item<int64_t>();
    int64_t resolution3 = resolution * resolution * resolution;

    float voxel_size = srcs.at("voxel_size").Item<float>();

    // Shape / transform indexers, no data involved
    NDArrayIndexer voxel_indexer({resolution, resolution, resolution});

    // Real data indexer
    NDArrayIndexer voxel_block_buffer_indexer(block_values, 4);

    // Plain arrays that does not require indexers
    int64_t* nb_indices_ptr = static_cast<int64_t*>(nb_indices.GetDataPtr());
    bool* nb_masks_ptr = static_cast<bool*>(nb_masks.GetDataPtr());
    int64_t* indices_ptr = static_cast<int64_t*>(indices.GetDataPtr());
    int64_t* block_keys_ptr = static_cast<int64_t*>(block_keys.GetDataPtr());

    int n_blocks = indices.GetShape()[0];
    int64_t n = n_blocks * resolution3;

    // Output
    core::Tensor count(std::vector<int>{0}, {}, core::Dtype::Int32,
                       block_values.GetDevice());
    core::Tensor points({std::min(n * 3, int64_t(10000000)), 3},
                        core::Dtype::Float32, block_values.GetDevice());
    int* count_ptr = static_cast<int*>(count.GetDataPtr());
    float* points_ptr = static_cast<float*>(points.GetDataPtr());

    CUDALauncher::LaunchGeneralKernel(n, [=] OPEN3D_DEVICE(
                                                 int64_t workload_idx) {
        // Natural index (0, N) -> (block_idx, voxel_idx)
        int64_t workload_block_idx = workload_idx / resolution3;
        int64_t block_idx = indices_ptr[workload_block_idx];
        int64_t voxel_idx = workload_idx % resolution3;

        /// Coordinate transform
        // block_idx -> (x_block, y_block, z_block)
        int64_t xb = block_keys_ptr[block_idx * 3 + 0];
        int64_t yb = block_keys_ptr[block_idx * 3 + 1];
        int64_t zb = block_keys_ptr[block_idx * 3 + 2];

        // voxel_idx -> (x_voxel, y_voxel, z_voxel)
        int64_t xv, yv, zv;
        voxel_indexer.WorkloadToCoord(voxel_idx, &xv, &yv, &zv);
        int64_t workload_voxel;
        voxel_block_buffer_indexer.CoordToWorkload(xv, yv, zv, block_idx,
                                                   &workload_voxel);
        float* voxel_ptr = static_cast<float*>(
                voxel_block_buffer_indexer.GetDataPtrFromWorkload(
                        workload_voxel));
        float tsdf_o = voxel_ptr[0];
        float weight_o = voxel_ptr[1];
        if (weight_o == 0) return;

        int64_t x = xb * resolution + xv;
        int64_t y = yb * resolution + yv;
        int64_t z = zb * resolution + zv;

        for (int i = 0; i < 3; ++i) {
            int64_t xv_i = xv + int64_t(i == 0);
            int64_t yv_i = yv + int64_t(i == 1);
            int64_t zv_i = zv + int64_t(i == 2);

            int64_t dxb = xv_i / resolution;
            int64_t dyb = yv_i / resolution;
            int64_t dzb = zv_i / resolution;

            int64_t nb_idx = (dxb + 1) + (dyb + 1) * 3 + (dzb + 1) * 9;

            // if (nb_indices_ptr[13 * n_blocks + workload_block_idx] !=
            //     block_idx) {
            //     printf("wrong!\n");
            // }
            bool block_mask_i =
                    nb_masks_ptr[nb_idx * n_blocks + workload_block_idx];
            if (!block_mask_i) continue;

            int64_t block_idx_i =
                    nb_indices_ptr[nb_idx * n_blocks + workload_block_idx];
            int64_t workload_voxel_i;
            voxel_block_buffer_indexer.CoordToWorkload(
                    xv_i - dxb * resolution, yv_i - dyb * resolution,
                    zv_i - dzb * resolution, block_idx_i, &workload_voxel_i);
            float* voxel_ptr_i = static_cast<float*>(
                    voxel_block_buffer_indexer.GetDataPtrFromWorkload(
                            workload_voxel_i));

            float tsdf_i = voxel_ptr_i[0];
            float weight_i = voxel_ptr_i[1];
            // printf("%f %f\n", tsdf_i, weight_i);

            if (weight_i > 0 && tsdf_i * tsdf_o < 0) {
                float ratio = tsdf_i / (tsdf_i - tsdf_o);

                int idx = atomicAdd(count_ptr, 1);

                points_ptr[idx * 3 + 0] =
                        voxel_size * (x + ratio * int(i == 0));
                points_ptr[idx * 3 + 1] =
                        voxel_size * (y + ratio * int(i == 1));
                points_ptr[idx * 3 + 2] =
                        voxel_size * (z + ratio * int(i == 2));
            }
        }
    });

    int total_count = count.Item<int>();
    dsts.emplace("points", points.Slice(0, 0, total_count));
    utility::LogInfo("surface extraction finished");
}

void CUDAMarchingCubesKernel(
        const std::unordered_map<std::string, Tensor>& srcs,
        std::unordered_map<std::string, Tensor>& dsts) {
    // Decode input tensors
    static std::vector<std::string> src_attrs = {
            "indices",    "inv_indices",  "nb_indices", "nb_masks",
            "block_keys", "block_values", "voxel_size", "resolution",
    };
    for (auto& k : src_attrs) {
        if (srcs.count(k) == 0) {
            utility::LogError(
                    "[CUDAMarchingCubesKernel] expected Tensor {} in srcs, but "
                    "did not receive",
                    k);
        }
    }
    utility::LogInfo("surface extraction starts");

    Tensor indices = srcs.at("indices");
    Tensor inv_indices = srcs.at("inv_indices");
    Tensor nb_indices = srcs.at("nb_indices");
    Tensor nb_masks = srcs.at("nb_masks");
    Tensor block_keys = srcs.at("block_keys");
    Tensor block_values = srcs.at("block_values");

    // Parameters
    int64_t resolution = srcs.at("resolution").Item<int64_t>();
    int64_t resolution3 = resolution * resolution * resolution;

    float voxel_size = srcs.at("voxel_size").Item<float>();

    // Shape / transform indexers, no data involved
    NDArrayIndexer voxel_indexer({resolution, resolution, resolution});

    // Output
    if (dsts.count("mesh_structure") == 0) {
        utility::LogError(
                "[CUDAMarchingCubesKernel] expected Tensor mesh_structure in "
                "srcs, but "
                "did not receive");
    }
    Tensor mesh_structure = dsts.at("mesh_structure");

    // Real data indexer
    NDArrayIndexer voxel_block_buffer_indexer(block_values, 4);
    NDArrayIndexer mesh_structure_indexer(mesh_structure, 4);

    // Plain arrays that does not require indexers
    int64_t* nb_indices_ptr = static_cast<int64_t*>(nb_indices.GetDataPtr());
    bool* nb_masks_ptr = static_cast<bool*>(nb_masks.GetDataPtr());
    int64_t* indices_ptr = static_cast<int64_t*>(indices.GetDataPtr());
    int64_t* inv_indices_ptr = static_cast<int64_t*>(inv_indices.GetDataPtr());
    int64_t* block_keys_ptr = static_cast<int64_t*>(block_keys.GetDataPtr());

    int n_blocks = indices.GetShape()[0];
    int64_t n = n_blocks * resolution3;

    // Pass 0: analyze mesh structure, set up one-on-one correspondences
    CUDALauncher::LaunchGeneralKernel(n, [=] OPEN3D_DEVICE(
                                                 int64_t workload_idx) {
        // Natural index (0, N) -> (block_idx, voxel_idx)
        int64_t workload_block_idx = workload_idx / resolution3;
        int64_t voxel_idx = workload_idx % resolution3;

        // voxel_idx -> (x_voxel, y_voxel, z_voxel)
        int64_t xv, yv, zv;
        voxel_indexer.WorkloadToCoord(voxel_idx, &xv, &yv, &zv);

        // Check per-vertex sign in the cube to determine cube type
        int table_idx = 0;
        for (int i = 0; i < 8; ++i) {
            int64_t xv_i = xv + vtx_shifts[i][0];
            int64_t yv_i = yv + vtx_shifts[i][1];
            int64_t zv_i = zv + vtx_shifts[i][2];

            int64_t dxb = xv_i / resolution;
            int64_t dyb = yv_i / resolution;
            int64_t dzb = zv_i / resolution;

            int64_t nb_idx = (dxb + 1) + (dyb + 1) * 3 + (dzb + 1) * 9;

            bool block_mask_i =
                    nb_masks_ptr[nb_idx * n_blocks + workload_block_idx];
            if (!block_mask_i) return;

            int64_t block_idx_i =
                    nb_indices_ptr[nb_idx * n_blocks + workload_block_idx];
            int64_t workload_voxel_i;
            voxel_block_buffer_indexer.CoordToWorkload(
                    xv_i - dxb * resolution, yv_i - dyb * resolution,
                    zv_i - dzb * resolution, block_idx_i, &workload_voxel_i);
            float* voxel_ptr_i = static_cast<float*>(
                    voxel_block_buffer_indexer.GetDataPtrFromWorkload(
                            workload_voxel_i));

            float tsdf_i = voxel_ptr_i[0];
            float weight_i = voxel_ptr_i[1];
            if (weight_i == 0) return;

            table_idx |= ((tsdf_i < 0) ? (1 << i) : 0);
        }

        int64_t workload_mesh_struct_idx;
        mesh_structure_indexer.CoordToWorkload(xv, yv, zv, workload_block_idx,
                                               &workload_mesh_struct_idx);
        int* mesh_struct_ptr =
                static_cast<int*>(mesh_structure_indexer.GetDataPtrFromWorkload(
                        workload_mesh_struct_idx));
        mesh_struct_ptr[3] = table_idx;

        if (table_idx == 0 || table_idx == 255) return;

        // Check per-edge sign in the cube to determine cube type
        int edges_with_vertices = edge_table[table_idx];
        for (int i = 0; i < 12; ++i) {
            if (edges_with_vertices & (1 << i)) {
                int64_t xv_i = xv + edge_shifts[i][0];
                int64_t yv_i = yv + edge_shifts[i][1];
                int64_t zv_i = zv + edge_shifts[i][2];
                int edge_i = edge_shifts[i][3];

                int dxb = xv_i / resolution;
                int dyb = yv_i / resolution;
                int dzb = zv_i / resolution;

                int nb_idx = (dxb + 1) + (dyb + 1) * 3 + (dzb + 1) * 9;

                int64_t block_idx_i =
                        nb_indices_ptr[nb_idx * n_blocks + workload_block_idx];
                int64_t workload_mesh_struct_i;
                mesh_structure_indexer.CoordToWorkload(
                        xv_i - dxb * resolution, yv_i - dyb * resolution,
                        zv_i - dzb * resolution, inv_indices_ptr[block_idx_i],
                        &workload_mesh_struct_i);
                if (indices_ptr[inv_indices_ptr[block_idx_i]] != block_idx_i) {
                    printf("inv indices error!\n");
                }
                int* mesh_struct_ptr_i = static_cast<int*>(
                        mesh_structure_indexer.GetDataPtrFromWorkload(
                                workload_mesh_struct_i));

                // Non-atomic write, but we are safe
                mesh_struct_ptr_i[edge_i] = -1;
            }
        }
    });

    // Pass 1: allocate and assign vertices with normals
    core::Tensor count(std::vector<int>{0}, {}, core::Dtype::Int32,
                       block_values.GetDevice());
    core::Tensor vertices({std::min(n * 3, int64_t(10000000)), 3},
                          core::Dtype::Float32, block_values.GetDevice());
    core::Tensor normals({std::min(n * 3, int64_t(10000000)), 3},
                         core::Dtype::Float32, block_values.GetDevice());
    int* count_ptr = static_cast<int*>(count.GetDataPtr());
    float* vertices_ptr = static_cast<float*>(vertices.GetDataPtr());
    float* normals_ptr = static_cast<float*>(normals.GetDataPtr());
    CUDALauncher::LaunchGeneralKernel(n, [=] OPEN3D_DEVICE(
                                                 int64_t workload_idx) {
        // Natural index (0, N) -> (block_idx, voxel_idx)
        int64_t workload_block_idx = workload_idx / resolution3;
        int64_t block_idx = indices_ptr[workload_block_idx];
        int64_t voxel_idx = workload_idx % resolution3;

        // block_idx -> (x_block, y_block, z_block)
        int64_t xb = block_keys_ptr[block_idx * 3 + 0];
        int64_t yb = block_keys_ptr[block_idx * 3 + 1];
        int64_t zb = block_keys_ptr[block_idx * 3 + 2];

        // voxel_idx -> (x_voxel, y_voxel, z_voxel)
        int64_t xv, yv, zv;
        voxel_indexer.WorkloadToCoord(voxel_idx, &xv, &yv, &zv);

        // global coordinate (in voxels)
        int64_t x = xb * resolution + xv;
        int64_t y = yb * resolution + yv;
        int64_t z = zb * resolution + zv;

        // Obtain voxel's mesh struct ptr
        int64_t workload_mesh_struct_idx;
        mesh_structure_indexer.CoordToWorkload(xv, yv, zv, workload_block_idx,
                                               &workload_mesh_struct_idx);
        int* mesh_struct_ptr =
                static_cast<int*>(mesh_structure_indexer.GetDataPtrFromWorkload(
                        workload_mesh_struct_idx));

        // Early quit -- no allocated vertex to compute
        if (mesh_struct_ptr[0] != -1 && mesh_struct_ptr[1] != -1 &&
            mesh_struct_ptr[2] != -1) {
            return;
        }

        // Obtain voxel ptr
        int64_t workload_voxel_idx;
        voxel_block_buffer_indexer.CoordToWorkload(xv, yv, zv, block_idx,
                                                   &workload_voxel_idx);
        float* voxel_ptr = static_cast<float*>(
                voxel_block_buffer_indexer.GetDataPtrFromWorkload(
                        workload_voxel_idx));
        float tsdf_o = voxel_ptr[0];
        if (voxel_ptr[1] == 0) {
            printf("voxel weight error!\n");
        }

        // Normal buffers
        float n_o[3], n_e[3];

        // Offset vertex coordinates (plus / minus one voxel)
        int64_t xvs[2], yvs[2], zvs[2];
        // Delta block coordinates (unchanged or plus / minus one block)
        int64_t dxbs[2], dybs[2], dzbs[2];
        // TSDF
        float tsdfs[2];

        // First compute normal at origin
        for (int axis = 0; axis < 3; ++axis) {
            xvs[1] = xv + int(axis == 0);
            yvs[1] = yv + int(axis == 1);
            zvs[1] = zv + int(axis == 2);

            xvs[0] = xv - int(axis == 0);
            yvs[0] = yv - int(axis == 1);
            zvs[0] = zv - int(axis == 2);

            dxbs[1] = xvs[1] / resolution;
            dybs[1] = xvs[1] / resolution;
            dzbs[1] = zvs[1] / resolution;

            dxbs[0] = xvs[0] >= 0 ? 0 : -1;
            dybs[0] = yvs[0] >= 0 ? 0 : -1;
            dzbs[0] = zvs[0] >= 0 ? 0 : -1;

            for (int k = 0; k < 2; ++k) {
                int64_t nb_idx_k =
                        (dxbs[k] + 1) + (dybs[k] + 1) * 3 + (dzbs[k] + 1) * 9;
                bool block_mask_k =
                        nb_masks_ptr[nb_idx_k * n_blocks + workload_block_idx];
                int64_t block_idx_k = nb_indices_ptr[nb_idx_k * n_blocks +
                                                     workload_block_idx];
                int64_t workload_voxel_k;
                voxel_block_buffer_indexer.CoordToWorkload(
                        xvs[k] - dxbs[k] * resolution,
                        yvs[k] - dybs[k] * resolution,
                        zvs[k] - dzbs[k] * resolution, block_idx_k,
                        &workload_voxel_k);
                float* voxel_ptr_k = static_cast<float*>(
                        voxel_block_buffer_indexer.GetDataPtrFromWorkload(
                                workload_voxel_k));
                tsdfs[k] = block_mask_k ? voxel_ptr_k[0] : 0;
            }
            n_o[axis] = (tsdfs[1] - tsdfs[0]) / (2 * voxel_size);
        }

        // Enumerate 3 edges in the voxel
        for (int e = 0; e < 3; ++e) {
            int vertex_idx = mesh_struct_ptr[e];
            if (vertex_idx != -1) continue;

            int64_t xv_e = xv + int(e == 0);
            int64_t yv_e = yv + int(e == 1);
            int64_t zv_e = zv + int(e == 2);

            int dxb = xv_e / resolution;
            int dyb = yv_e / resolution;
            int dzb = zv_e / resolution;

            // First query tsdf
            int64_t nb_idx = (dxb + 1) + (dyb + 1) * 3 + (dzb + 1) * 9;

            bool block_mask_e =
                    nb_masks_ptr[nb_idx * n_blocks + workload_block_idx];
            if (!block_mask_e) {
                printf("edge: block mask error!\n");
            }

            int64_t block_idx_e =
                    nb_indices_ptr[nb_idx * n_blocks + workload_block_idx];
            int64_t workload_voxel_e;
            voxel_block_buffer_indexer.CoordToWorkload(
                    xv_e - dxb * resolution, yv_e - dyb * resolution,
                    zv_e - dzb * resolution, block_idx_e, &workload_voxel_e);
            float* voxel_ptr_e = static_cast<float*>(
                    voxel_block_buffer_indexer.GetDataPtrFromWorkload(
                            workload_voxel_e));
            float tsdf_e = voxel_ptr_e[0];
            if (voxel_ptr_e[1] == 0) {
                printf("edge: weight error!\n");
            }
            if (tsdf_e * tsdf_o > 0) {
                printf("tsdf error: %f %f\n", tsdf_e, tsdf_o);
                return;
            }

            // Then compute normals
            for (int axis = 0; axis < 3; ++axis) {
                xvs[1] = xv_e + int(axis == 0);
                yvs[1] = yv_e + int(axis == 1);
                zvs[1] = zv_e + int(axis == 2);

                xvs[0] = xv_e - int(axis == 0);
                yvs[0] = yv_e - int(axis == 1);
                zvs[0] = zv_e - int(axis == 2);

                dxbs[1] = xvs[1] / resolution;
                dybs[1] = xvs[1] / resolution;
                dzbs[1] = zvs[1] / resolution;

                dxbs[0] = xvs[0] >= 0 ? 0 : -1;
                dybs[0] = yvs[0] >= 0 ? 0 : -1;
                dzbs[0] = zvs[0] >= 0 ? 0 : -1;

                for (int k = 0; k < 2; ++k) {
                    int64_t nb_idx_k = (dxbs[k] + 1) + (dybs[k] + 1) * 3 +
                                       (dzbs[k] + 1) * 9;
                    bool block_mask_k = nb_masks_ptr[nb_idx_k * n_blocks +
                                                     workload_block_idx];
                    int64_t block_idx_k = nb_indices_ptr[nb_idx_k * n_blocks +
                                                         workload_block_idx];
                    int64_t workload_voxel_k;
                    voxel_block_buffer_indexer.CoordToWorkload(
                            xvs[k] - dxbs[k] * resolution,
                            yvs[k] - dybs[k] * resolution,
                            zvs[k] - dzbs[k] * resolution, block_idx_k,
                            &workload_voxel_k);
                    float* voxel_ptr_k = static_cast<float*>(
                            voxel_block_buffer_indexer.GetDataPtrFromWorkload(
                                    workload_voxel_k));
                    tsdfs[k] = block_mask_k ? voxel_ptr_k[0] : 0;
                }
                n_e[axis] = (tsdfs[1] - tsdfs[0]) / (2 * voxel_size);
            }

            float ratio = tsdf_e / (tsdf_e - tsdf_o);

            int idx = atomicAdd(count_ptr, 1);
            mesh_struct_ptr[e] = idx;
            /// printf("%d\n", idx);

            float ratio_x = (1 - ratio) * int(e == 0);
            float ratio_y = (1 - ratio) * int(e == 1);
            float ratio_z = (1 - ratio) * int(e == 2);

            vertices_ptr[3 * idx + 0] = voxel_size * (x + ratio_x);
            vertices_ptr[3 * idx + 1] = voxel_size * (y + ratio_y);
            vertices_ptr[3 * idx + 2] = voxel_size * (z + ratio_z);

            float nx = n_o[0] * (ratio) + n_e[0] * (1 - ratio);
            float ny = n_o[1] * (ratio) + n_e[1] * (1 - ratio);
            float nz = n_o[2] * (ratio) + n_e[2] * (1 - ratio);
            float norm = sqrtf(nx * nx + ny * ny + nz * nz);

            normals_ptr[3 * idx + 0] = nx / norm;
            normals_ptr[3 * idx + 1] = ny / norm;
            normals_ptr[3 * idx + 2] = nz / norm;
        }
    });

    int total_count = count.Item<int>();
    utility::LogInfo("Total vertex count = {}", total_count);
    vertices = vertices.Slice(0, 0, total_count);
    normals = normals.Slice(0, 0, total_count);
    dsts.emplace("vertices", vertices);
    dsts.emplace("normals", normals);
}

void GeneralEWCUDA(const std::unordered_map<std::string, Tensor>& srcs,
                   std::unordered_map<std::string, Tensor>& dsts,
                   GeneralEWOpCode op_code) {
    switch (op_code) {
        case GeneralEWOpCode::Unproject:
            CUDAUnprojectKernel(srcs, dsts);
            break;
        case GeneralEWOpCode::TSDFTouch:
            CUDATSDFTouchKernel(srcs, dsts);
            break;
        case GeneralEWOpCode::TSDFIntegrate:
            CUDATSDFIntegrateKernel(srcs, dsts);
            break;
        case GeneralEWOpCode::TSDFSurfaceExtraction:
            CUDASurfaceExtractionKernel(srcs, dsts);
            break;
        case GeneralEWOpCode::MarchingCubes:
            CUDAMarchingCubesKernel(srcs, dsts);
            break;
        case GeneralEWOpCode::RayCasting:
            break;
        case GeneralEWOpCode::Debug: {
            int64_t n = 10;
            CUDALauncher::LaunchGeneralKernel(
                    n, [=] OPEN3D_HOST_DEVICE(int64_t workload_idx) {});
            break;
        }
        default:
            break;
    }
}

}  // namespace kernel
}  // namespace core
}  // namespace open3d
