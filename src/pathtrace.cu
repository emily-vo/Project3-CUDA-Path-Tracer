#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/device_ptr.h>
#include <thrust/random.h>
#include <thrust/remove.h>
#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#define MATSORT 0
#define STREAMCOMP 1
#define ERRORCHECK 1
#define ACCELSTRUCT 1
#define PROCTEXT 1

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char *msg, const char *file, int line) {
#if ERRORCHECK
	cudaDeviceSynchronize();
	cudaError_t err = cudaGetLastError();
	if (cudaSuccess == err) {
		return;
	}

	fprintf(stderr, "CUDA error");
	if (file) {
		fprintf(stderr, " (%s:%d)", file, line);
	}
	fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
	getchar();
#  endif
	exit(EXIT_FAILURE);
#endif
}

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
	int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
	return thrust::default_random_engine(h);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
	int iter, glm::vec3* image) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		glm::vec3 pix = image[index];

		glm::ivec3 color;
		color.x = glm::clamp((int)(pix.x / iter * 255.0), 0, 255);
		color.y = glm::clamp((int)(pix.y / iter * 255.0), 0, 255);
		color.z = glm::clamp((int)(pix.z / iter * 255.0), 0, 255);

		// Each thread writes one pixel location in the texture (textel)
		pbo[index].w = 0;
		pbo[index].x = color.x;
		pbo[index].y = color.y;
		pbo[index].z = color.z;
	}
}

static Scene * hst_scene = NULL;
static glm::vec3 * dev_image = NULL;
static Geom * dev_geoms = NULL;
static Material * dev_materials = NULL;
static PathSegment * dev_paths = NULL;
static ShadeableIntersection * dev_intersections = NULL;
static glm::vec3 * dev_textures = NULL;
static LinearKDNode *dev_kdtree = NULL;
// TODO: static variables for device memory, any extra info you need, etc
// ...

void pathtraceInit(Scene *scene) {
	hst_scene = scene;
	const Camera &cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

	cudaMalloc(&dev_geoms, scene->sortedGeoms.size() * sizeof(Geom));
	cudaMemcpy(dev_geoms, scene->sortedGeoms.data(), scene->sortedGeoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	cudaMalloc(&dev_textures, scene->textureData.size() * sizeof(glm::vec3));
	cudaMemcpy(dev_textures, scene->textureData.data(), scene->textureData.size() * sizeof(glm::vec3), cudaMemcpyHostToDevice);
	
	cudaMalloc(&dev_kdtree, scene->flatKDTree.size() * sizeof(LinearKDNode));
	cudaMemcpy(dev_kdtree, scene->flatKDTree.data(), scene->flatKDTree.size() * sizeof(LinearKDNode), cudaMemcpyHostToDevice);

	checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
	cudaFree(dev_image);  // no-op if dev_image is null
	cudaFree(dev_paths);
	cudaFree(dev_geoms);
	cudaFree(dev_materials);
	cudaFree(dev_intersections);
	cudaFree(dev_textures);
	// TODO: clean up any extra device memory you created

	cudaFree(dev_kdtree);

	checkCUDAError("pathtraceFree");
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment & segment = pathSegments[index];

		segment.ray.origin = cam.position;
		segment.color = glm::vec3(1.0f, 1.0f, 1.0f);


		// implement antialiasing by jittering the ray
		thrust::default_random_engine rng = makeSeededRandomEngine(iter, index, 0);
		thrust::uniform_real_distribution<float> u01(0, 1);
		glm::vec2 jitter(u01(rng), u01(rng));
		glm::vec2 pixel = glm::vec2(x, y) + jitter;
		//pixel = glm::vec2(x, y);
		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)pixel.x - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)pixel.y - (float)cam.resolution.y * 0.5f)
		);

		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;
	}
}

__global__ void computeIntersectionsKD(int depth, int num_paths, PathSegment *pathSegments,
	Geom *geoms, LinearKDNode *kdtree, int geoms_size,
	ShadeableIntersection * intersections,
	Material *mats, glm::vec3 *dev_textures) {
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths) {
		PathSegment pathSegment = pathSegments[path_index];

		float t;
		float boundsT;
		glm::vec3 intersect_point;
		glm::vec3 normal;
		glm::vec2 uv(0);
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		bool outside = true;

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;
		glm::vec2 tmp_uv;

		// Traverse through kd tree
		int toVisitOffset = 0, currentNodeIndex = 0;
		int nodesToVisit[64];
		while (true) {
			LinearKDNode node = kdtree[currentNodeIndex];
			boundsT = boundsIntersectionTest(node.bounds, pathSegment.ray);
			if (boundsT != -1.f) {
				if (node.nPrimitives > 0) {
					for (int i = 0; i < node.nPrimitives; ++i) {
						Geom &geom = geoms[node.primitivesOffset + i];
						if (geom.type == CUBE) {
							t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
						}
						else if (geom.type == SPHERE) {
							t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
						}
						else if (geom.type == TRIANGLE) {
							t = triangleIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
						}
						if (t > 0.0f && t_min > t) {
							t_min = t;
							hit_geom_index = node.primitivesOffset + i;
							intersect_point = tmp_intersect;
							normal = tmp_normal;
							uv = tmp_uv;
						}
					}
					if (toVisitOffset == 0) { break; }
					currentNodeIndex = nodesToVisit[--toVisitOffset];
				}
				else {
					nodesToVisit[toVisitOffset++] = node.secondChildOffset;
					currentNodeIndex = currentNodeIndex + 1;
				}
			}
			else {
				if (toVisitOffset == 0) { break; }
				currentNodeIndex = nodesToVisit[--toVisitOffset];
			}
		}

		if (hit_geom_index == -1) {
			intersections[path_index].t = -1.0f;
		}
		else {
			//The ray hits something
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = geoms[hit_geom_index].materialid;
			intersections[path_index].surfaceNormal = normal;
			Material material = mats[geoms[hit_geom_index].materialid];

			// compute the uvs
			glm::vec3 pt = multiplyMV(geoms[hit_geom_index].inverseTransform, glm::vec4(intersect_point, 1.0f));
			if (geoms[hit_geom_index].type == SPHERE || geoms[hit_geom_index].type == DIAMOND || geoms[hit_geom_index].type == MANDELBULB) {
				intersections[path_index].uvs = computeSphereUVs(pt);
			}
			else if (geoms[hit_geom_index].type == CUBE) {
				intersections[path_index].uvs = computeCubeUVs(pt);
			}
			else if (geoms[hit_geom_index].type == TRIANGLE) {
				intersections[path_index].uvs = GetTriangleUVs(geoms[hit_geom_index], pt);
			}

			// compute the normal if there is a normal map
			if (material.normMapOffset > -1) {
				glm::vec3 t, b, n;
				n = normal;
				computeSphereTBN(geoms[hit_geom_index], pt, normal, &t, &b);
				glm::mat3 tangentToWorld(t, b, n);
				// glm::mat3 worldToTangent = glm::inverse(tangentToWorld);
				int pixel_x = intersections[path_index].uvs[0] * (material.n_m_width - 1);
				int pixel_y = (1.f - intersections[path_index].uvs[1]) * (material.n_m_height - 1);
				int idx = pixel_y * material.n_m_height + pixel_x + material.normMapOffset;
				glm::vec3 norm = dev_textures[idx] * 2.f - 1.f;
				intersections[path_index].surfaceNormal = tangentToWorld * norm;
			}
		}
	}
}

// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(
	int depth
	, int num_paths
	, PathSegment * pathSegments
	, Geom * geoms
	, int geoms_size
	, ShadeableIntersection * intersections
	, Material * materials
	, glm::vec3 * dev_textures
)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths)
	{
		PathSegment pathSegment = pathSegments[path_index];

		float t;
		glm::vec3 intersect_point;
		glm::vec3 normal;
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		bool outside = true;

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;

		glm::vec3 resColor(1.0f);
		// naive parse through global geoms
		for (int i = 0; i < geoms_size; i++)
		{
			Geom & geom = geoms[i];
			
			if (geom.type == CUBE)
			{
				t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == SPHERE)
			{
				t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == DIAMOND)
			{
				t = diamondIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == MANDELBULB)
			{
				t = mandelbulbIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside, &resColor);
				//t = -1;
			}
			else if (geom.type == TRIANGLE)
			{
				t = triangleIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
				//t = -1;
			}

			// TODO: add more intersection tests here... triangle? metaball? CSG?

			// Compute the minimum t from the intersection tests to determine what
			// scene geometry object was hit first.
			if (t > 0.0f && t_min > t)
			{
				t_min = t;
				hit_geom_index = i;
				intersect_point = tmp_intersect;
				normal = tmp_normal;

			}
		}

		if (hit_geom_index == -1)
		{
			intersections[path_index].t = -1.0f;
		}
		else
		{
			//The ray hits something
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = geoms[hit_geom_index].materialid;
			intersections[path_index].surfaceNormal = normal;
			//pathSegment.color *= resColor;
			pathSegment.color *= glm::vec3(1.f, 0.f, 1.f);
			/*if (geoms[hit_geom_index].type == MANDELBULB) {
				materials[geoms[hit_geom_index].materialid].color = resColor;
			}*/
			glm::vec3 pt = multiplyMV(geoms[hit_geom_index].inverseTransform, glm::vec4(intersect_point, 1.0f));
			if (geoms[hit_geom_index].type == SPHERE || geoms[hit_geom_index].type == DIAMOND || geoms[hit_geom_index].type == MANDELBULB) {
				intersections[path_index].uvs = computeSphereUVs(pt);
			}
			else if (geoms[hit_geom_index].type == CUBE) {
				intersections[path_index].uvs = computeCubeUVs(pt);
			}
			else if (geoms[hit_geom_index].type == TRIANGLE) {
				intersections[path_index].uvs = GetTriangleUVs(geoms[hit_geom_index], pt);
			}

			Material & mat = materials[intersections[path_index].materialId];
			if (mat.normMapOffset > -1) {
				glm::vec3 t, b, n;
				n = normal;
				computeSphereTBN(geoms[hit_geom_index], pt, normal, &t, &b);
				glm::mat3 tangentToWorld(t, b, n);
				// glm::mat3 worldToTangent = glm::inverse(tangentToWorld);
				int pixel_x = intersections[path_index].uvs[0] * (mat.n_m_width - 1);
				int pixel_y = (1.f - intersections[path_index].uvs[1]) * (mat.n_m_height - 1);
				int idx = pixel_y * mat.n_m_height + pixel_x + mat.normMapOffset;
				glm::vec3 norm = dev_textures[idx] * 2.f - 1.f;
				intersections[path_index].surfaceNormal = tangentToWorld * norm;
			}
		}
	}
}

// LOOK: "fake" shader demonstrating what you might do with the info in
// a ShadeableIntersection, as well as how to use thrust's random number
// generator. Observe that since the thrust random number generator basically
// adds "noise" to the iteration, the image should start off noisy and get
// cleaner as more iterations are computed.
//
// Note that this shader does NOT do a BSDF evaluation!
// Your shaders should handle that - this can allow techniques such as
// bump mapping.

__forceinline__ __device__ glm::vec3 getIntersection(PathSegment pathSegment, ShadeableIntersection intersection) {
	glm::vec3 intersectionPoint = pathSegment.ray.origin + (pathSegment.ray.direction * intersection.t);
	return intersectionPoint;
}

__forceinline__ __device__ glm::vec3 BxDF_Diffuse(Material material, glm::vec3 &normal, glm::vec3 &wo, thrust::default_random_engine &rng, glm::vec3 *wi, float *pdf) {
	*wi = calculateRandomDirectionInHemisphere(normal, rng);
	float cosTheta = glm::abs(glm::dot(normal, *wi));
	*pdf = cosTheta * InvPi;
	return material.color * InvPi * cosTheta;
}

__forceinline__ __device__ float lerp(float a, float b, float t) {
	return (1.0f - t) * a + t * b;
}

__forceinline__ __device__ glm::vec3 lerp(glm::vec3 a, glm::vec3 b, float t) {
	return (1.0f - t) * a + t * b;
}

__forceinline__ __device__ glm::vec2 SineWave(glm::vec2 p) {
	float pi = 3.14159;
	float A = 0.2;
	float w = 10.0 * pi;
	float t = 30.0*pi / 180.0;
	float y = sin(w*p.x + t) * A;
	return glm::vec2(p.x, p.y + y);
}


__global__ void shadeMaterials(int iter, int num_paths, ShadeableIntersection * shadeableIntersections, PathSegment * pathSegments, Material * materials, int depth, glm::vec3 *dev_textures)
{
	int index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index >= num_paths) return;
	if (pathSegments[index].remainingBounces == 0) return;

	ShadeableIntersection intersection = shadeableIntersections[index];
	if (intersection.t > 0.0f) {
		thrust::default_random_engine rng = makeSeededRandomEngine(iter, index, depth);
		Material material = materials[intersection.materialId];
		glm::vec3 materialColor = material.color;

		// If the material indicates that the object was a light, "light" the ray
		// terminate path tracing if a light is hit
		if (material.emittance > 0.0f) {
			pathSegments[index].color *= (materialColor * material.emittance);
			pathSegments[index].remainingBounces = 0;
		}
		else {
			glm::vec3 isectPt = getPointOnRay(pathSegments[index].ray, intersection.t);
			// get uvs based on geometry
			// get tangentToWorld based on geometry
			// get color from map on uvs
			if (material.textureOffset == -2) {
				// shade the material magenta if there is a texture loading error
				pathSegments[index].color = glm::vec3(1.f, 0.f, 1.f);
				pathSegments[index].remainingBounces = 0;
			}
			if (material.textureOffset > -1) {
#if PROCTEXT
				glm::vec2 f_uv = SineWave(intersection.uvs);
				glm::vec3 a(0.5, 0.5, 0.5);
				glm::vec3 b(.5, 0.5, 0.5);
				glm::vec3 c(2.0, 1.0, 0.0);
				glm::vec3 d(.50, 0.20, 0.25);
				float t = f_uv.x * f_uv.y;
				glm::vec3 color = palette(t, a, b, c, d);
				pathSegments[index].color *= color;
#else
				int pixel_x = intersection.uvs[0] * (material.tex_width - 1);
				int pixel_y = (1.f - intersection.uvs[1]) * (material.tex_height - 1);
				int idx = pixel_y * material.tex_width + pixel_x + material.textureOffset;
				glm::vec3 texColor = dev_textures[idx];
				pathSegments[index].color *= texColor;
#endif
				

				
			}
			

			scatterRay(pathSegments[index], isectPt, intersection.surfaceNormal, material, rng);
			pathSegments[index].remainingBounces--;

		}
	}
	else {
		pathSegments[index].color = glm::vec3(0.0f);
		pathSegments[index].remainingBounces = 0;
	}
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3 * image, PathSegment * iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
		image[iterationPath.pixelIndex] += iterationPath.color;
	}
}

struct rayDeath
{
	__host__ __device__ bool operator()(const PathSegment &pathSegment)
	{
		return pathSegment.remainingBounces > 0;
	}
};

struct materialCmp
{
	__host__ __device__ 	bool operator()(const ShadeableIntersection &a, const ShadeableIntersection &b)
	{
		return a.materialId < b.materialId;
	}
};

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4 *pbo, int frame, int iter) {
	if (iter % 10 == 0) printf("iteration %d\n", iter);
	/*using time_point_t = std::chrono::high_resolution_clock::time_point;
    time_point_t start_time = std::chrono::high_resolution_clock::now();*/

	const int traceDepth = hst_scene->state.traceDepth;
	const Camera &cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	
	///////////////////////////////////////////////////////////////////////////

	// Recap:
	// * Initialize array of path rays (using rays that come out of the camera)
	//   * You can pass the Camera object to that kernel.
	//   * Each path ray must carry at minimum a (ray, color) pair,
	//   * where color starts as the multiplicative identity, white = (1, 1, 1).
	//   * This has already been done for you.
	// * For each depth:
	//   * Compute an intersection in the scene for each path ray.
	//     A very naive version of this has been implemented for you, but feel
	//     free to add more primitives and/or a better algorithm.
	//     Currently, intersection distance is recorded as a parametric distance,
	//     t, or a "distance along the ray." t = -1.0 indicates no intersection.
	//     * Color is attenuated (multiplied) by reflections off of any object
	//   * TODO: Stream compact away all of the terminated paths.
	//     You may use either your implementation or `thrust::remove_if` or its
	//     cousins.
	//     * Note that you can't really use a 2D kernel launch any more - switch
	//       to 1D.
	//   * TODO: Shade the rays that intersected something or didn't bottom out.
	//     That is, color the ray by performing a color computation according
	//     to the shader, then generate a new ray to continue the ray path.
	//     We recommend just updating the ray's PathSegment in place.
	//     Note that this step may come before or after stream compaction,
	//     since some shaders you write may also cause a path to terminate.
	// * Finally, add this iteration's results to the image. This has been done
	//   for you.

	// TODO: perform one iteration of path tracing

	generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (cam, iter, traceDepth, dev_paths);
	checkCUDAError("generate camera ray");

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks
	// SORTING
#if MATSORT
	thrust::device_ptr<ShadeableIntersection> dv_intersections(dev_intersections);
	thrust::device_ptr<PathSegment> dv_paths(dev_paths);
#endif

	bool iterationComplete = false;
	while (!iterationComplete) {

		// clean shading chunks
		cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

		// tracing
		dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;
		
#if ACCELSTRUCT
		computeIntersectionsKD << <numblocksPathSegmentTracing, blockSize1d >> > (
			depth,
			num_paths,
			dev_paths,
			dev_geoms,
			dev_kdtree,
			hst_scene->geoms.size(),
			dev_intersections,
			dev_materials,
			dev_textures
			);
#else
		computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
			depth
			, num_paths
			, dev_paths
			, dev_geoms
			, hst_scene->geoms.size()
			, dev_intersections
			, dev_materials
			, dev_textures
			);
#endif
		

		

		checkCUDAError("trace one bounce");
		cudaDeviceSynchronize();
		


		// TODO:
		// --- Shading Stage ---
		// Shade path segments based on intersections and generate new rays by
	  // evaluating the BSDF.
	  // Start off with just a big kernel that handles all the different
	  // materials you have in the scenefile.
	  // TODO: compare between directly shading the path segments and shading
	  // path segments that have been reshuffled to be contiguous in memory.
#if MATSORT
		thrust::sort_by_key(dv_intersections, dv_intersections + num_paths,
			dv_paths, materialCmp());
#endif

		shadeMaterials << <numblocksPathSegmentTracing, blockSize1d >> > (
			iter,
			num_paths,
			dev_intersections,
			dev_paths,
			dev_materials,
			depth,
			dev_textures
			);
		depth++;

#if STREAMCOMP
		PathSegment *path_end = thrust::partition(thrust::device, dev_paths, dev_paths + num_paths, rayDeath());
		num_paths = path_end - dev_paths;
		if (iter % 10 == 0) printf("%d\n", num_paths);
		iterationComplete = (num_paths == 0) || (depth == traceDepth);
#else
		iterationComplete = (depth == traceDepth); 
#endif

		/*cudaDeviceSynchronize();
		time_point_t end_time = std::chrono::high_resolution_clock::now();
		std::chrono::duration<double, std::milli> dur = end_time - start_time;
		float elapsed_time = static_cast<decltype(elapsed_time)>(dur.count());
		std::cout << "elapsed time: " << elapsed_time << "ms." << std::endl;*/
	}

	// Assemble this iteration and apply it to the image
	num_paths = dev_path_end - dev_paths;
	dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
	finalGather << <numBlocksPixels, blockSize1d >> > (num_paths, dev_image, dev_paths);

	///////////////////////////////////////////////////////////////////////////

	// Send results to OpenGL buffer for rendering
	sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_image);

	// Retrieve image from GPU
	cudaMemcpy(hst_scene->state.image.data(), dev_image,
		pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

	checkCUDAError("pathtrace");
}
