// FFX_VariableShading.h
//
// Copyright (c) 2020 Advanced Micro Devices, Inc. All rights reserved.
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

/*
	Variable Rate Shading for ReShade
	Ported by: Lord of Lunacy
	
	This is a port of the VRS Image generation shader in AMD's FidelityFX,
	currently it is lacking support for tile sizes besides 8, and the
	option for more shading rates.
	
	To make the shader compatible with ReshadeFX, I had to replace the wave intrinsics
	with atomic intrinsics.
*/

//////////////////////////////////////////////////////////////////////////
// VariableShading constant buffer parameters:
//
// Resolution The resolution of the surface a VRSImage is to be generated for
// TileSize Hardware dependent tile size (query from API; 8 on AMD RDNA2 based GPUs)
// VarianceCutoff Maximum luminance variance acceptable to accept reduced shading rate
// MotionFactor Length of the motion vector * MotionFactor gets deducted from luminance variance
// to allow lower VS rates on fast moving objects
//
//////////////////////////////////////////////////////////////////////////

#define DIVIDE_ROUNDING_UP(a, b) (uint(uint(a + b - 1) / uint(b)))

#define TILE_SIZE 8
#define VRS_IMAGE_SIZE (uint2(DIVIDE_ROUNDING_UP(BUFFER_WIDTH, TILE_SIZE), DIVIDE_ROUNDING_UP(BUFFER_HEIGHT, TILE_SIZE)))
#define THREAD_GROUPS (uint2(DIVIDE_ROUNDING_UP(VRS_IMAGE_SIZE.x, 2), DIVIDE_ROUNDING_UP(VRS_IMAGE_SIZE.y, 2)))

texture BackBuffer : COLOR;
texture VRS {Width = VRS_IMAGE_SIZE.x; Height = VRS_IMAGE_SIZE.y; Format = R8;};

sampler sBackBuffer {Texture = BackBuffer;};
sampler sVRS {Texture = VRS;};

storage wVRS {Texture = VRS;};

static const int2 g_Resolution = int2(BUFFER_WIDTH, BUFFER_HEIGHT);
static const uint g_TileSize = TILE_SIZE;
uniform float g_VarianceCutoff<
	ui_type = "slider";
	ui_label = "Variance Cutoff";
	ui_tooltip = "Maximum luminance variance acceptable to accept reduced shading rate";
	ui_min = 0; ui_max = 0.1;
	ui_step = 0.0001;
> = 0.05;
uniform float g_MotionFactor<
	ui_type = "slider";
	ui_label = "Motion Factor";
	ui_tooltip = "Length of the motion vector * MotionFactor gets deducted from luminance variance \n"
				 "to allow lower VS rates on fast moving objects";
	ui_min = 0; ui_max = 1;
	ui_step = 0.001;
> = 0.5;

uniform bool ShowOverlay <
	ui_label = "Show Overlay";
> = 1;

struct FFX_VariableShading_CB
{
    uint 	    width, height;
    uint    	tileSize;
    float       varianceCutoff;
    float       motionFactor;
};

// Forward declaration of functions that need to be implemented by shader code using this technique
float   FFX_VariableShading_ReadLuminance(int2 pos)
{
	return dot(tex2Dfetch(sBackBuffer, pos).rgb, float3(0.299, 0.587, 0.114));
}
float2  FFX_VariableShading_ReadMotionVec2D(int2 pos)
{
	return float2(0, 0);
}
void    FFX_VariableShading_WriteVrsImage(int2 pos, uint value)
{
	tex2Dstore(wVRS, pos, float4(float(value)/255, 0, 0, 0));
}

static const uint FFX_VARIABLESHADING_RATE1D_1X = 0x0;
static const uint FFX_VARIABLESHADING_RATE1D_2X = 0x1;
static const uint FFX_VARIABLESHADING_RATE1D_4X = 0x2;
#define FFX_VARIABLESHADING_MAKE_SHADING_RATE(x,y) ((x << 2) | (y))

static const uint FFX_VARIABLESHADING_RATE_1X1 = FFX_VARIABLESHADING_MAKE_SHADING_RATE(FFX_VARIABLESHADING_RATE1D_1X, FFX_VARIABLESHADING_RATE1D_1X); // 0;
static const uint FFX_VARIABLESHADING_RATE_1X2 = FFX_VARIABLESHADING_MAKE_SHADING_RATE(FFX_VARIABLESHADING_RATE1D_1X, FFX_VARIABLESHADING_RATE1D_2X); // 0x1;
static const uint FFX_VARIABLESHADING_RATE_2X1 = FFX_VARIABLESHADING_MAKE_SHADING_RATE(FFX_VARIABLESHADING_RATE1D_2X, FFX_VARIABLESHADING_RATE1D_1X); // 0x4;
static const uint FFX_VARIABLESHADING_RATE_2X2 = FFX_VARIABLESHADING_MAKE_SHADING_RATE(FFX_VARIABLESHADING_RATE1D_2X, FFX_VARIABLESHADING_RATE1D_2X); // 0x5;
static const uint FFX_VARIABLESHADING_RATE_2X4 = FFX_VARIABLESHADING_MAKE_SHADING_RATE(FFX_VARIABLESHADING_RATE1D_2X, FFX_VARIABLESHADING_RATE1D_4X); // 0x6;
static const uint FFX_VARIABLESHADING_RATE_4X2 = FFX_VARIABLESHADING_MAKE_SHADING_RATE(FFX_VARIABLESHADING_RATE1D_4X, FFX_VARIABLESHADING_RATE1D_2X); // 0x9;
static const uint FFX_VARIABLESHADING_RATE_4X4 = FFX_VARIABLESHADING_MAKE_SHADING_RATE(FFX_VARIABLESHADING_RATE1D_4X, FFX_VARIABLESHADING_RATE1D_4X); // 0xa;

static const uint FFX_VariableShading_ThreadCount1D = TILE_SIZE;
static const uint FFX_VariableShading_NumBlocks1D = 2;

static const uint FFX_VariableShading_SampleCount1D = FFX_VariableShading_ThreadCount1D + 2;

groupshared uint FFX_VariableShading_LdsGroupReduce;

static const uint FFX_VariableShading_ThreadCount = FFX_VariableShading_ThreadCount1D * FFX_VariableShading_ThreadCount1D;
static const uint FFX_VariableShading_SampleCount = FFX_VariableShading_SampleCount1D * FFX_VariableShading_SampleCount1D;
static const uint FFX_VariableShading_NumBlocks = FFX_VariableShading_NumBlocks1D * FFX_VariableShading_NumBlocks1D;

groupshared float3 FFX_VariableShading_LdsVariance[FFX_VariableShading_SampleCount];
groupshared float FFX_VariableShading_LdsMin[FFX_VariableShading_SampleCount];
groupshared float FFX_VariableShading_LdsMax[FFX_VariableShading_SampleCount];

float FFX_VariableShading_GetLuminance(int2 pos)
{
    return FFX_VariableShading_ReadLuminance(pos);
}

int FFX_VariableShading_FlattenLdsOffset(int2 coord)
{
    coord += 1;
    return coord.y * FFX_VariableShading_SampleCount1D + coord.x;
}

groupshared uint4 diffX;
groupshared uint4 diffY;
groupshared uint4 diffZ;

int floatToOrderedInt( float floatVal ) {
 int intVal = asint( floatVal );
 return (intVal >= 0 ) ? intVal : intVal ^ 0x7FFFFFFF;
}

float orderedIntToFloat( int intVal ) {
 return asfloat( (intVal >= 0) ? intVal : intVal ^ 0x7FFFFFFF);
}

//--------------------------------------------------------------------------------------//
// Main function */                                  //
//--------------------------------------------------------------------------------------//
void FFX_VariableShading_GenerateVrsImage(uint3 id : SV_DispatchThreadID, uint3 Gtid : SV_GroupThreadID)
{
	uint3 Gid = uint3(id.x / TILE_SIZE, id.y / TILE_SIZE, 0);
    int2 tileOffset = Gid.xy * FFX_VariableShading_ThreadCount1D * 2;
    int2 baseOffset = tileOffset + int2(-2, -2);
	uint Gidx = Gtid.y * TILE_SIZE + Gtid.x;
    uint index = Gidx;
	
	// sample source texture (using motion vectors)
    while (index < FFX_VariableShading_SampleCount)
    {
        int2 index2D = 2 * int2(index % FFX_VariableShading_SampleCount1D, index / FFX_VariableShading_SampleCount1D);
        float4 lum = 0;
        lum.x = FFX_VariableShading_GetLuminance(baseOffset + index2D + int2(0, 0));
        lum.y = FFX_VariableShading_GetLuminance(baseOffset + index2D + int2(1, 0));
        lum.z = FFX_VariableShading_GetLuminance(baseOffset + index2D + int2(0, 1));
        lum.w = FFX_VariableShading_GetLuminance(baseOffset + index2D + int2(1, 1));

        // compute the 2x1, 1x2 and 2x2 variance inside the 2x2 coarse pixel region
        float3 delta;
        delta.x = max(abs(lum.x - lum.y), abs(lum.z - lum.w));
        delta.y = max(abs(lum.x - lum.z), abs(lum.y - lum.w));
        float2 minmax = float2(min(min(min(lum.x, lum.y), lum.z), lum.w), max(max(max(lum.x, lum.y), lum.z), lum.w));
        delta.z = minmax.y - minmax.x;

        // reduce variance value for fast moving pixels
        float v = length(FFX_VariableShading_ReadMotionVec2D(baseOffset + index2D));
        v *= g_MotionFactor;
        delta -= v;
        minmax.y -= v;

        // store variance as well as min/max luminance
        FFX_VariableShading_LdsVariance[index] = delta;
        FFX_VariableShading_LdsMin[index] = minmax.x;
        FFX_VariableShading_LdsMax[index] = minmax.y;

        index += FFX_VariableShading_ThreadCount;
    }
	//Initialized here to reduce the number of barrier statements
	if(Gtid.x == 0 && Gtid.y == 0)
	{
		diffX = 0;
		diffY = 0;
		diffZ = 0;
	}
	barrier();
	
    // upper left coordinate in LDS
    int2 threadUV = Gtid.xy;

    // look at neighbouring coarse pixels, to combat burn in effect due to frame dependence
    float3 delta = FFX_VariableShading_LdsVariance[FFX_VariableShading_FlattenLdsOffset(threadUV + int2(0, 0))];

    // read the minimum luminance for neighbouring coarse pixels
    float minNeighbour = FFX_VariableShading_LdsMin[FFX_VariableShading_FlattenLdsOffset(threadUV + int2(0, -1))];
    minNeighbour = min(minNeighbour, FFX_VariableShading_LdsMin[FFX_VariableShading_FlattenLdsOffset(threadUV + int2(-1, 0))]);
    minNeighbour = min(minNeighbour, FFX_VariableShading_LdsMin[FFX_VariableShading_FlattenLdsOffset(threadUV + int2(0, 1))]);
    minNeighbour = min(minNeighbour, FFX_VariableShading_LdsMin[FFX_VariableShading_FlattenLdsOffset(threadUV + int2(1, 0))]);
    float dMin = max(0, FFX_VariableShading_LdsMin[FFX_VariableShading_FlattenLdsOffset(threadUV + int2(0, 0))] - minNeighbour);

    // read the maximum luminance for neighbouring coarse pixels
    float maxNeighbour = FFX_VariableShading_LdsMax[FFX_VariableShading_FlattenLdsOffset(threadUV + int2(0, -1))];
    maxNeighbour = max(maxNeighbour, FFX_VariableShading_LdsMax[FFX_VariableShading_FlattenLdsOffset(threadUV + int2(-1, 0))]);
    maxNeighbour = max(maxNeighbour, FFX_VariableShading_LdsMax[FFX_VariableShading_FlattenLdsOffset(threadUV + int2(0, 1))]);
    maxNeighbour = max(maxNeighbour, FFX_VariableShading_LdsMax[FFX_VariableShading_FlattenLdsOffset(threadUV + int2(1, 0))]);
    float dMax = max(0, maxNeighbour - FFX_VariableShading_LdsMax[FFX_VariableShading_FlattenLdsOffset(threadUV + int2(0, 0))]);

    // assume higher luminance based on min & max values gathered from neighbouring pixels
    delta = max(0, delta + dMin + dMax);

    // Reduction: find maximum variance within VRS tile
	uint idx = (Gtid.y & (FFX_VariableShading_NumBlocks1D - 1)) * FFX_VariableShading_NumBlocks1D + (Gtid.x & (FFX_VariableShading_NumBlocks1D - 1));
	atomicMax(diffX[idx], floatToOrderedInt(delta.x));
	atomicMax(diffY[idx], floatToOrderedInt(delta.y));
	atomicMax(diffZ[idx], floatToOrderedInt(delta.z));
	
	
	// write out shading rates to VRS image
    if (Gidx < FFX_VariableShading_NumBlocks)
    {
        float varH = orderedIntToFloat(diffX[Gidx]);
        float varV = orderedIntToFloat(diffY[Gidx]);
        float var = orderedIntToFloat(diffZ[Gidx]);;
        uint shadingRate = FFX_VARIABLESHADING_MAKE_SHADING_RATE(FFX_VARIABLESHADING_RATE1D_1X, FFX_VARIABLESHADING_RATE1D_1X);

        if (var < g_VarianceCutoff)
        {
            shadingRate = FFX_VARIABLESHADING_MAKE_SHADING_RATE(FFX_VARIABLESHADING_RATE1D_2X, FFX_VARIABLESHADING_RATE1D_2X);
        }
        else
        {
            if (varH > varV)
            {
                shadingRate = FFX_VARIABLESHADING_MAKE_SHADING_RATE(FFX_VARIABLESHADING_RATE1D_1X, (varV > g_VarianceCutoff) ? FFX_VARIABLESHADING_RATE1D_1X : FFX_VARIABLESHADING_RATE1D_2X);
            }
            else
            {
                shadingRate = FFX_VARIABLESHADING_MAKE_SHADING_RATE((varH > g_VarianceCutoff) ? FFX_VARIABLESHADING_RATE1D_1X : FFX_VARIABLESHADING_RATE1D_2X, FFX_VARIABLESHADING_RATE1D_1X);
            }
        }
        // Store
        FFX_VariableShading_WriteVrsImage(Gid.xy* FFX_VariableShading_NumBlocks1D + uint2(Gidx / FFX_VariableShading_NumBlocks1D, Gidx % FFX_VariableShading_NumBlocks1D), shadingRate);
    }
}

struct VERTEX_OUT
{
    float4 vPosition : SV_POSITION;
	float2 texcoord : TEXCOORD;
};

VERTEX_OUT mainVS(uint id : SV_VertexID)
{
    VERTEX_OUT output;
    output.vPosition = float4(float2(id & 1, id >> 1) * float2(4, -4) + float2(-1, 1), 0, 1);
	output.texcoord = float2(0, 0);
    return output;
}

float4 mainPS(VERTEX_OUT input) : SV_Target
{
	if(!ShowOverlay) discard;
    int2 pos = input.vPosition.xy / g_TileSize;
    // encode different shading rates as colors
    float3 color = float3(1, 1, 1);

    switch (255 * (tex2Dfetch(sVRS, pos).r))
    {
    case FFX_VARIABLESHADING_RATE_1X1:
        color = float3(0.5, 0.0, 0.0);
        break;
    case FFX_VARIABLESHADING_RATE_1X2:
        color = float3(0.5, 0.5, 0.0);
        break;
    case FFX_VARIABLESHADING_RATE_2X1:
        color = float3(0.5, 0.25, 0.0);
        break;
    case FFX_VARIABLESHADING_RATE_2X2:
        color = float3(0.0, 0.5, 0.0);
        break;
    case FFX_VARIABLESHADING_RATE_2X4:
        color = float3(0.25, 0.25, 0.5);
        break;
    case FFX_VARIABLESHADING_RATE_4X2:
        color = float3(0.5, 0.25, 0.5);
        break;
    case FFX_VARIABLESHADING_RATE_4X4:
        color = float3(0.0, 0.5, 0.5);
        break;
    }

    // add grid
	color = lerp(color, tex2Dfetch(sBackBuffer, input.vPosition.xy).rgb, 0.35);
    int2 grid = int2(input.vPosition.xy) % g_TileSize;
    bool border = (grid.x == 0) || (grid.y == 0);

	return float4(color, 0.5) * (border ? 0.5f : 1.0f);
}

technique VariableRateShading
{
	pass
	{
		ComputeShader = FFX_VariableShading_GenerateVrsImage<TILE_SIZE, TILE_SIZE>;
		DispatchSizeX = THREAD_GROUPS.x;
		DispatchSizeY = THREAD_GROUPS.y;
	}
	pass
	{
		VertexShader = mainVS;
		PixelShader = mainPS;
	}
}
