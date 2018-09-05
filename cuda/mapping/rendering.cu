#include "rendering.h"
#include "prefixsum.h"
#include "Timer.hpp"

#define minMaxSubSample 8
#define renderingBlockSizeX 16
#define renderingBlockSizeY 16

struct Projection {

	int cols, rows;

	Matrix3f RcurrInv;
	float3 tcurr;
	float depthMax, depthMin;
	float fx, fy, cx, cy;

	uint * noRenderingBlocks;
	uint noVisibleBlocks;

	PtrSz<HashEntry> visibleBlocks;
	mutable PtrStepSz<float> zRangeX;
	mutable PtrStep<float> zRangeY;
	mutable PtrSz<RenderingBlock> renderingBlockList;

	__device__ inline float2 project(const float3 & pt3d) const {

		float2 pt2d;
		pt2d.x = fx * pt3d.x / pt3d.z + cx;
		pt2d.y = fy * pt3d.y / pt3d.z + cy;
		return pt2d;
	}

	__device__ inline bool projectBlock(const int3 & pos,
										RenderingBlock & block) const {

		block.upperLeft = make_int2(cols, rows) / minMaxSubSample;
		block.lowerRight = make_int2(-1, -1);
		block.zRange = make_float2(DeviceMap::DepthMax, DeviceMap::DepthMin);
		for (int corner = 0; corner < 8; ++corner) {
			int3 tmp = pos;
			tmp.x += (corner & 1) ? 1 : 0;
			tmp.y += (corner & 2) ? 1 : 0;
			tmp.z += (corner & 4) ? 1 : 0;
			float3 pt3d = tmp * DeviceMap::BlockSize * DeviceMap::VoxelSize;
			pt3d = RcurrInv * (pt3d - tcurr);
			if (pt3d.z < 2e-1)
				continue;

			float2 pt2d = project(pt3d) / minMaxSubSample;

			if (block.upperLeft.x > floor(pt2d.x))
				block.upperLeft.x = (int) floor(pt2d.x);
			if (block.lowerRight.x < ceil(pt2d.x))
				block.lowerRight.x = (int) ceil(pt2d.x);
			if (block.upperLeft.y > floor(pt2d.y))
				block.upperLeft.y = (int) floor(pt2d.y);
			if (block.lowerRight.y < ceil(pt2d.y))
				block.lowerRight.y = (int) ceil(pt2d.y);
			if (block.zRange.x > pt3d.z)
				block.zRange.x = pt3d.z;
			if (block.zRange.y < pt3d.z)
				block.zRange.y = pt3d.z;
		}

		if (block.upperLeft.x < 0)
			block.upperLeft.x = 0;
		if (block.upperLeft.y < 0)
			block.upperLeft.y = 0;
		if (block.lowerRight.x >= cols)
			block.lowerRight.x = cols - 1;
		if (block.lowerRight.y >= rows)
			block.lowerRight.y = rows - 1;
		if (block.upperLeft.x > block.lowerRight.x)
			return false;
		if (block.upperLeft.y > block.lowerRight.y)
			return false;
		if (block.zRange.x < DeviceMap::DepthMin)
			block.zRange.x = DeviceMap::DepthMin;
		if (block.zRange.y < DeviceMap::DepthMin)
			return false;

		return true;
	}

	__device__ inline void createRenderingBlockList(int & offset,
			const RenderingBlock & block, int & nx, int & ny) const {

		for (int y = 0; y < ny; ++y)
			for (int x = 0; x < ny; ++x) {
				if (offset < renderingBlockList.size) {
					RenderingBlock & b(renderingBlockList[offset++]);
					b.upperLeft.x = block.upperLeft.x + x * renderingBlockSizeX;
					b.upperLeft.y = block.upperLeft.y + y * renderingBlockSizeY;
					b.lowerRight.x = block.upperLeft.x + renderingBlockSizeX;
					b.lowerRight.y = block.upperLeft.y + renderingBlockSizeY;
					if (b.lowerRight.x > block.lowerRight.x)
						b.lowerRight.x = block.lowerRight.x;
					if (b.lowerRight.y > block.lowerRight.y)
						b.lowerRight.y = block.lowerRight.y;
					b.zRange = block.zRange;
				}
			}
	}

	__device__ inline void operator()() const {

		int x = blockDim.x * blockIdx.x + threadIdx.x;
		if(x >= noVisibleBlocks || visibleBlocks[x].ptr == EntryAvailable)
			return;

		bool valid = false;
		uint requiredNoBlocks = 0;
		RenderingBlock block;
		int nx, ny;

		valid = projectBlock(visibleBlocks[x].pos, block);
		float dx = (float) block.lowerRight.x - block.upperLeft.x + 1;
		float dy = (float) block.lowerRight.y - block.upperLeft.y + 1;
		nx = __float2int_ru(dx / renderingBlockSizeX);
		ny = __float2int_ru(dy / renderingBlockSizeY);
		if (valid) {
			requiredNoBlocks = nx * ny;
			uint totalNoBlocks = *noRenderingBlocks + requiredNoBlocks;
			if (totalNoBlocks >= renderingBlockList.size) {
				requiredNoBlocks = 0;
				valid = false;
			}
		}

		int offset = ComputeOffset<1024>(requiredNoBlocks, noRenderingBlocks);
		if (valid && offset != -1)
			createRenderingBlockList(offset, block, nx, ny);
	}

	__device__ inline void fillBlocks() const {

		int x = threadIdx.x;
		int y = threadIdx.y;

		int block = blockIdx.x * 4 + blockIdx.y;
		if (block >= *noRenderingBlocks)
			return;

		RenderingBlock & b(renderingBlockList[block]);

		int xpos = b.upperLeft.x + x;
		if (xpos > b.lowerRight.x || xpos >= zRangeX.cols)
			return;

		int ypos = b.upperLeft.y + y;
		if (ypos > b.lowerRight.y || ypos >= zRangeX.rows)
			return;

		float * minPtr = & zRangeX.ptr(ypos)[xpos];
		float * maxPtr = & zRangeY.ptr(ypos)[xpos];

		atomicMin(minPtr, b.zRange.x);
		atomicMax(maxPtr, b.zRange.y);

		return;
	}
};

__global__ void projectBlockKernel(const Projection proj) {

	proj();
}

__global__ void fillBlocksKernel(const Projection proj) {

	proj.fillBlocks();
}

__global__ void fillDepthRangeKernel(PtrStepSz<float> zX) {

	int x = blockDim.x * blockIdx.x + threadIdx.x;
	int y = blockDim.y * blockIdx.y + threadIdx.y;
	if(x >= zX.cols || y >= zX.rows)
		return;

	zX.ptr(y)[x] = 3.5;
}

bool createRenderingBlock(const DeviceArray<HashEntry> & visibleBlocks,
						  DeviceArray2D<float> & zRangeX,
						  DeviceArray2D<float> & zRangeY,
						  const float & depthMax,
						  const float & depthMin,
						  DeviceArray<RenderingBlock> & renderingBlockList,
						  DeviceArray<uint> & noRenderingBlocks,
						  Matrix3f RviewInv,
						  float3 tview,
						  uint noVisibleBlocks,
						  float fx,
						  float fy,
						  float cx,
						  float cy) {

	int cols = zRangeX.cols();
	int rows = zRangeX.rows();
	noRenderingBlocks.zero();
	Projection proj;
	proj.fx = fx;
	proj.fy = fy;
	proj.cx = cx;
	proj.cy = cy;
	proj.visibleBlocks = visibleBlocks;
	proj.cols = 640;
	proj.rows = 480;
	proj.RcurrInv = RviewInv;
	proj.tcurr = tview;
	proj.zRangeX = zRangeX;
	proj.zRangeY = zRangeY;
	proj.depthMax = depthMax;
	proj.depthMin = depthMin;
	proj.noRenderingBlocks = noRenderingBlocks;
	proj.noVisibleBlocks = noVisibleBlocks;
	proj.renderingBlockList = renderingBlockList;

	dim3 block, thread;
	thread = dim3(16, 4);
	block.x = cv::divUp(cols, thread.x);
	block.y = cv::divUp(rows, thread.y);

	Timer::Start("test", "fillDepthRangeKernel");
	zRangeY.zero();
	fillDepthRangeKernel<<<block, thread>>>(zRangeX);
	SafeCall(cudaGetLastError());
	SafeCall(cudaDeviceSynchronize());
	Timer::Stop("test", "fillDepthRangeKernel");

	thread = dim3(1024);
	block = dim3(cv::divUp((int) noVisibleBlocks, block.x));

	Timer::Start("test", "projectBlockKernel");
	projectBlockKernel<<<block, thread>>>(proj);
	SafeCall(cudaGetLastError());
	SafeCall(cudaDeviceSynchronize());
	Timer::Stop("test", "projectBlockKernel");

	uint totalBlocks;
	noRenderingBlocks.download((void*) &totalBlocks);

	if (totalBlocks == 0) {
		return false;
	}

	thread = dim3(16, 16);
	block.x = (uint)ceil((float)totalBlocks / 4);
	block.y = 4;

	Timer::Start("test", "fillBlocksKernel");
	fillBlocksKernel<<<block, thread>>>(proj);
	SafeCall(cudaGetLastError());
	SafeCall(cudaDeviceSynchronize());
	Timer::Stop("test", "fillBlocksKernel");

	return true;
}

struct Rendering {

	int cols, rows;
	DeviceMap map;
	mutable PtrStep<float4> vmap;
	mutable PtrStep<float3> nmap;
	PtrStep<float> zRangeX;
	PtrStep<float> zRangeY;
	float invfx, invfy, cx, cy;
	Matrix3f Rview, RviewInv;
	float3 tview;

	__device__ inline float readSdf(const float3 & pt3d) {
		Voxel voxel = map.FindVoxel(pt3d);
		if (voxel.sdfW == 0)
			return 1.f;
		return voxel.GetSdf();
	}

	__device__ inline float readSdfInterped(const float3 & pt) {

		float3 xyz = pt - floor(pt);
		float sdf[2], result[4];
		sdf[0] = map.FindVoxel(pt).GetSdf();
		sdf[1] = map.FindVoxel(pt + make_float3(1, 0, 0)).GetSdf();
		result[0] = (1.0f - xyz.x) * sdf[0] + xyz.x * sdf[1];

		sdf[0] = map.FindVoxel(pt + make_float3(0, 1, 0)).GetSdf();
		sdf[1] = map.FindVoxel(pt + make_float3(1, 1, 0)).GetSdf();
		result[1] = (1.0f - xyz.x) * sdf[0] + xyz.x * sdf[1];
		result[2] = (1.0f - xyz.y) * result[0] + xyz.y * result[1];

		sdf[0] = map.FindVoxel(pt + make_float3(0, 0, 1)).GetSdf();
		sdf[1] = map.FindVoxel(pt + make_float3(1, 0, 1)).GetSdf();
		result[0] = (1.0f - xyz.x) * sdf[0] + xyz.x * sdf[1];

		sdf[0] = map.FindVoxel(pt + make_float3(0, 1, 1)).GetSdf();
		sdf[1] = map.FindVoxel(pt + make_float3(1, 1, 1)).GetSdf();
		result[1] = (1.0f - xyz.x) * sdf[0] + xyz.x * sdf[1];
		result[3] = (1.0f - xyz.y) * result[0] + xyz.y * result[1];

		return (1.0f - xyz.z) * result[2] + xyz.z * result[3];
	}

	__device__ inline bool readNormal(const float3 & pt, float3 & n) {

		float sdf[6];
		sdf[0] = readSdfInterped(pt + make_float3(1, 0, 0));
		if(isnan(sdf[0]) || sdf[0] == 1.0f)
			return false;

		sdf[1] = readSdfInterped(pt + make_float3(-1, 0, 0));
		if(isnan(sdf[1]) || sdf[1] == 1.0f)
			return false;

		sdf[2] = readSdfInterped(pt + make_float3(0, 1, 0));
		if(isnan(sdf[2]) || sdf[2] == 1.0f)
			return false;

		sdf[3] = readSdfInterped(pt + make_float3(0, -1, 0));
		if(isnan(sdf[3]) || sdf[3] == 1.0f)
			return false;

		sdf[4] = readSdfInterped(pt + make_float3(0, 0, 1));
		if(isnan(sdf[4]) || sdf[4] == 1.0f)
			return false;

		sdf[5] = readSdfInterped(pt + make_float3(0, 0, -1));
		if(isnan(sdf[5]) || sdf[5] == 1.0f)
			return false;

		n = make_float3(sdf[0] - sdf[1], sdf[2] - sdf[3], sdf[4] - sdf[5]);
		n = normalised(RviewInv * n);
		return true;
	}


	__device__ inline bool readNormalFast(const float3 & pt, float3 & n) {

		float sdf[6];
		sdf[0] = readSdf(pt + make_float3(1, 0, 0));
		if(isnan(sdf[0]) || sdf[0] == 1.0f)
			return false;

		sdf[1] = readSdf(pt + make_float3(-1, 0, 0));
		if(isnan(sdf[1]) || sdf[1] == 1.0f)
			return false;

		sdf[2] = readSdf(pt + make_float3(0, 1, 0));
		if(isnan(sdf[2]) || sdf[2] == 1.0f)
			return false;

		sdf[3] = readSdf(pt + make_float3(0, -1, 0));
		if(isnan(sdf[3]) || sdf[3] == 1.0f)
			return false;

		sdf[4] = readSdf(pt + make_float3(0, 0, 1));
		if(isnan(sdf[4]) || sdf[4] == 1.0f)
			return false;

		sdf[5] = readSdf(pt + make_float3(0, 0, -1));
		if(isnan(sdf[5]) || sdf[5] == 1.0f)
			return false;

		n = make_float3(sdf[0] - sdf[1], sdf[2] - sdf[3], sdf[4] - sdf[5]);
		n = normalised(RviewInv * n);
		return true;
	}

	__device__ inline void operator()() {

		int x = blockDim.x * blockIdx.x + threadIdx.x;
		int y = blockDim.y * blockIdx.y + threadIdx.y;
		if (x >= cols || y >= rows)
			return;

		int2 locId;
		locId.x = __float2int_rd((float) x / minMaxSubSample);
		locId.y = __float2int_rd((float) y / minMaxSubSample);

		float2 zRange;
		zRange.x = zRangeX.ptr(locId.y)[locId.x];
		zRange.y = zRangeY.ptr(locId.y)[locId.x];
		if(zRange.y < 1e-3 || zRange.x < 1e-3 || isnan(zRange.x))
			return;

		float sdf = 1.0f;
		float stepScale = 2 * DeviceMap::TruncateDist * DeviceMap::voxelSizeInv;

		float3 pt3d;
		pt3d.z = zRange.x;
		pt3d.x = pt3d.z * (x - cx) * invfx;
		pt3d.y = pt3d.z * (y - cy) * invfy;
		float dist_s = norm(pt3d) * DeviceMap::voxelSizeInv;
		float3 block_s = Rview * pt3d + tview;
		block_s = block_s * DeviceMap::voxelSizeInv;

		pt3d.z = zRange.y;
		pt3d.x = pt3d.z * (x - cx) * invfx;
		pt3d.y = pt3d.z * (y - cy) * invfy;
		float dist_e = norm(pt3d) * DeviceMap::voxelSizeInv;
		float3 block_e = Rview * pt3d + tview;
		block_e = block_e * DeviceMap::voxelSizeInv;

		float3 dir = normalised(block_e - block_s);
		float3 result = block_s;

		bool found_pt = false;
		float step;
		while (dist_s < dist_e) {
			int3 blockPos = map.voxelPosToBlockPos(make_int3(result));
			HashEntry b = map.FindEntry(blockPos);
			if(b.ptr != EntryAvailable) {
				sdf = readSdf(result);
				if(sdf <= 0.1f && sdf >= -0.1f) {
					sdf = readSdfInterped(result);
				}

				if(sdf <= 0.0f)
					break;

				step = max(sdf * stepScale, 1.0f);
			}
			else
				step = DeviceMap::BlockSize;

			result += step * dir;
			dist_s += step;
		}

		if(sdf <= 0.0f) {
			step = sdf * stepScale;
			result += step * dir;

			sdf = readSdfInterped(result);

			step = sdf * stepScale;
			result += step * dir;
			found_pt = true;
		}

		if(found_pt) {
			float3 normal;
			if(readNormalFast(result, normal)) {
				result = RviewInv * (result * DeviceMap::VoxelSize - tview);
				vmap.ptr(y)[x] = make_float4(result, 1.0);
				nmap.ptr(y)[x] = normal;
			}
			else {
				vmap.ptr(y)[x] = make_float4(__int_as_float(0x7fffffff));
				nmap.ptr(y)[x] = make_float3(__int_as_float(0x7fffffff));
			}
		}
		else {
			vmap.ptr(y)[x] = make_float4(__int_as_float(0x7fffffff));
			nmap.ptr(y)[x] = make_float3(__int_as_float(0x7fffffff));
		}
	}
};

__global__ void RayCastKernel(Rendering cast) {
	cast();
}

void rayCast(DeviceMap map,
			 DeviceArray2D<float4> & vmap,
			 DeviceArray2D<float3> & nmap,
			 DeviceArray2D<float> & zRangeX,
			 DeviceArray2D<float> & zRangeY,
			 Matrix3f Rview,
			 Matrix3f RviewInv,
			 float3 tview,
			 float invfx,
			 float invfy,
			 float cx,
			 float cy) {

	int cols = vmap.cols();
	int rows = vmap.rows();

	Rendering cast;
	cast.cols = cols;
	cast.rows = rows;

	cast.map = map;
	cast.vmap = vmap;
	cast.nmap = nmap;
	cast.zRangeX = zRangeX;
	cast.zRangeY = zRangeY;
	cast.invfx = invfx;
	cast.invfy = invfy;
	cast.cx = cx;
	cast.cy = cy;
	cast.Rview = Rview;
	cast.RviewInv = RviewInv;
	cast.tview = tview;

	dim3 block, thread;
	thread.x = 32;
	thread.y = 8;
	block.x = cv::divUp(cols, thread.x);
	block.y = cv::divUp(rows, thread.y);

	Timer::Start("test", "RayCastKernel");
	RayCastKernel<<<block, thread>>>(cast);
	SafeCall(cudaGetLastError());
	SafeCall(cudaDeviceSynchronize());
	Timer::Stop("test", "RayCastKernel");

}