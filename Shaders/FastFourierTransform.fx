//--------------------------------------------------------------------------------------
// Copyright 2014 Intel Corporation
// All Rights Reserved
//
// Permission is granted to use, copy, distribute and prepare derivative works of this
// software for any purpose and without fee, provided, that the above copyright notice
// and this statement appear in all copies.  Intel makes no representations about the
// suitability of this software for any purpose.  THIS SOFTWARE IS PROVIDED "AS IS."
// INTEL SPECIFICALLY DISCLAIMS ALL WARRANTIES, EXPRESS OR IMPLIED, AND ALL LIABILITY,
// INCLUDING CONSEQUENTIAL AND OTHER INDIRECT DAMAGES, FOR THE USE OF THIS SOFTWARE,
// INCLUDING LIABILITY FOR INFRINGEMENT OF ANY PROPRIETARY RIGHTS, AND INCLUDING THE
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE.  Intel does not
// assume any responsibility for any errors which may appear in this software nor any
// responsibility to update it.
//--------------------------------------------------------------------------------------

/*
UAV Fast Fourier Transform ReShade Port

By: Lord Of Lunacy

This is my attempt at porting a FFT technique developed by Intel over to Reshade,
that uses unordered access views (UAV).
More details about it can be found here:

https://software.intel.com/content/www/us/en/develop/articles/implementation-of-fast-fourier-transform-for-image-processing-in-directx-10.html


Fast fourier transform is an optimized approach to applying discrete fourier transform,
and is used to convert images from the spatial domain to the frequency domain.
*/



/*
	Due to how the ButterflyTable is computed it is unable to generate an FFT
	with less than 5 passes (SUBBLOCK_SIZE of 32x32 is the minimum).
*/

//Butterfly Passes
#define FFTONE
#define FFTTWO
#define FFTTHREE
#define FFTFOUR
#define FFTFIVE
//#define FFTSIX
//#define FFTSEVEN
//#define FFTEIGHT

#include "ReShade.fxh"
#define PI 3.141592654
#define BUTTERFLY_COUNT 5 //must match the number of passes defined above
#define SUBBLOCK_SIZE (1 << (BUTTERFLY_COUNT)) //Subblocks are size 2^(BUTTERFLY_COUNT)
#define BLOCK_COUNT (uint2(BUFFER_SCREEN_SIZE / SUBBLOCK_SIZE) + uint2(1, 1))
#define TEXTURE_SIZE (uint2(BLOCK_COUNT * SUBBLOCK_SIZE))
#define ODD (BUTTERFLY_COUNT % 2)


texture ButterflyTable{Width = SUBBLOCK_SIZE; Height = BUTTERFLY_COUNT; Format = RGBA16F;};
sampler sButterflyTable{Texture = ButterflyTable;};
texture FFTInput{Width = TEXTURE_SIZE.x; Height = TEXTURE_SIZE.y; Format = RG8;};
sampler sFFTInput{Texture = FFTInput;};
texture Source{Width = TEXTURE_SIZE.x; Height = TEXTURE_SIZE.y; Format = RG16F;};
sampler sSource{Texture = Source;};
texture Source1{Width = TEXTURE_SIZE.x; Height = TEXTURE_SIZE.y; Format = RG16F;};
sampler sSource1{Texture = Source1;};
texture FrequencyDomain{Width = TEXTURE_SIZE.x; Height = TEXTURE_SIZE.y; Format = RG16F;};
sampler sFrequencyDomain{Texture = FrequencyDomain;};
texture FFTOutput{Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
sampler sFFTOutput{Texture = FFTOutput;};

float2 ComplexMult(float2 a, float2 b)
{
	return float2((a.x * b.x) - (a.y * b.y), (a.x * b.y) + (a.y * b.x));
}

uint BitwiseAnd(uint a, uint b)
{
	bool c = a;
	bool d = b;
	uint output;
	for(int i = 0; i < 32; i++)
	{
		c = a % 2;
		d = b % 2;
		output += exp2(i) * c * d;
		a /= 2;
		b /= 2;
	}
	return output;
}

uint BitwiseAndNot(uint a, uint b)
{
	bool c = a;
	bool d = b;
	uint output;
	for(int i = 0; i < 32; i++)
	{
		c = a % 2;
		d = 1 - (b % 2);
		output += exp2(i) * c * d;
		a /= 2;
		b /= 2;
	}
	return output;
}

uint LeftShift(uint a, uint b)
{
	return a * exp2(b);
}

uint RightShift(uint a, uint b)
{
	return a / exp2(b);
}

uint2 SubBlockCorner(float2 texcoord)
{
	uint x = int(texcoord.x * TEXTURE_SIZE.x) / SUBBLOCK_SIZE;
	uint y = int(texcoord.y * TEXTURE_SIZE.y) / SUBBLOCK_SIZE;
	x *= SUBBLOCK_SIZE;
	y *= SUBBLOCK_SIZE;
	return uint2(x, y);
}

uint2 SubBlockPosition(float2 texcoord)
{
	uint x = uint(texcoord.x * TEXTURE_SIZE.x);
	uint y = uint(texcoord.y * TEXTURE_SIZE.y);
	uint z = x / SUBBLOCK_SIZE;
	uint w = y / SUBBLOCK_SIZE;
	x = x - z * SUBBLOCK_SIZE;
	y = y - w * SUBBLOCK_SIZE;
	return uint2(x, y);
}

float4 GetButterflyValues(uint passIndex, uint x)
{
	int sectionWidth = LeftShift(2, passIndex);
	int halfSectionWidth = sectionWidth / 2;

	int sectionStartOffset = BitwiseAndNot(x, (sectionWidth - 1));
	int halfSectionOffset = BitwiseAnd(x, (halfSectionWidth - 1));
	int sectionOffset = BitwiseAnd(x, (sectionWidth - 1));
	
	
	float2 weights;
	uint2 indices;

	sincos( 2.0*PI*sectionOffset / (float)sectionWidth, weights.y, weights.x );
	weights.y = -weights.y;

	indices.x = sectionStartOffset + halfSectionOffset;
	indices.y = sectionStartOffset + halfSectionOffset + halfSectionWidth;

	if (passIndex == 0)
	{
		uint2 a = indices;
		uint2 reverse = 0;
		for(int i = 0; i < 32; i++) //bit reversal
		{
			reverse += exp2(31 - i) * (a % 2);
			a /= 2;
		}
		indices.x = RightShift(reverse.x, BitwiseAnd((32 - BUTTERFLY_COUNT), (SUBBLOCK_SIZE - 1)));
		indices.y = RightShift(reverse.y, BitwiseAnd((32 - BUTTERFLY_COUNT), (SUBBLOCK_SIZE - 1)));
	}
	return float4(weights, indices);
}

float2 ButterflyPass(float2 texcoord, uint passIndex, bool rowpass, bool inverse, sampler sourceSampler)
{
	uint2 position = SubBlockPosition(texcoord).xy;
	uint2 imagePosition = texcoord * TEXTURE_SIZE;
	uint2 corner = SubBlockCorner(texcoord).xy;
	float2 output;
	uint textureSampleX;
	if(rowpass) textureSampleX = position.x;
	else textureSampleX = position.y;

	
	uint2 Indices;
	float2 Weights;
	float4 IndicesAndWeights = tex2Dfetch(sButterflyTable, float4(textureSampleX, passIndex, 0, 0));
	Indices = IndicesAndWeights.zw;
	Weights = IndicesAndWeights.xy;
	

	float inputR1;
	float inputI1;
	float inputR2;
	float inputI2;

	if(rowpass)
	{
		Indices = Indices.xy + corner.xx;
		inputR1 = tex2Dfetch(sourceSampler, float4(Indices.x, imagePosition.y, 0, 0)).r;
		inputI1 = tex2Dfetch(sourceSampler, float4(Indices.x, imagePosition.y, 0, 0)).g;

		inputR2 = tex2Dfetch(sourceSampler, float4(Indices.y, imagePosition.y, 0, 0)).r;
		inputI2 = tex2Dfetch(sourceSampler, float4(Indices.y, imagePosition.y, 0, 0)).g;
	}
	else
	{
		Indices = Indices.xy + corner.yy;
		inputR1 = tex2Dfetch(sourceSampler, float4(imagePosition.x, Indices.x, 0, 0)).r;
		inputI1 = tex2Dfetch(sourceSampler, float4(imagePosition.x, Indices.x, 0, 0)).g;

		inputR2 = tex2Dfetch(sourceSampler, float4(imagePosition.x, Indices.y, 0, 0)).r;
		inputI2 = tex2Dfetch(sourceSampler, float4(imagePosition.x, Indices.y, 0, 0)).g;
	}

	if(inverse)
	{
		output.x = (inputR1 + Weights.x * inputR2 + Weights.y * inputI2) * 0.5;
		output.y = (inputI1 - Weights.y * inputR2 + Weights.x * inputI2) * 0.5;
	}
	else
	{
		output.x = inputR1 + Weights.x * inputR2 - Weights.y * inputI2;
		output.y = inputI1 + Weights.y * inputR2 + Weights.x * inputI2;
	}
	return output;
}

void DoNothingPS(out float4 output : SV_Target)
{
	output = 0;
	discard;
}

void ButterflyTablePS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float4 output : SV_Target)
{
	output = GetButterflyValues((texcoord.y * (BUTTERFLY_COUNT)), (texcoord.x * (SUBBLOCK_SIZE)));
}

void InputPS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	float2 coordinate = texcoord * (TEXTURE_SIZE / BUFFER_SCREEN_SIZE);
	float3 color = tex2D(ReShade::BackBuffer, coordinate).rgb;
	output = float2(dot(color, float3(0.3333, 0.3333, 0.3333)), 0);
	if ((coordinate.x > 1)) output = float2(0, 0);
	else if (coordinate.y > 1) output = float2(0, 0);
}

void MoveSourceToSource1PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = 0;
	if(bool(ODD))
	{
		output = tex2D(sSource, texcoord).rg;
	}
	else
	{
		discard;
	}
}

void MoveToFrequencyDomainPS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	if(bool(ODD))
	{
		output = tex2D(sSource, texcoord).rg;
	}
	else
	{
		output = tex2D(sSource1, texcoord).rg;
	}
}

void MoveToOutputPS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float output : SV_Target)
{
	float2 coordinate = texcoord * (BUFFER_SCREEN_SIZE / TEXTURE_SIZE);
	if(bool(ODD))
	{
		output = tex2D(sSource, coordinate).r;
	}
	else
	{
		output = tex2D(sSource1, coordinate).r;
	}
}

void FFTH1PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 0, 1, 0, sFFTInput);
}

void FFTH2PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 1, 1, 0, sSource);
}

void FFTH3PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 2, 1, 0, sSource1);
}

void FFTH4PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 3, 1, 0, sSource);
}

void FFTH5PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 4, 1, 0, sSource1);
}

void FFTH6PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 5, 1, 0, sSource);
}
		
void FFTH7PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 6, 1, 0, sSource1);
}

void FFTH8PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 7, 1, 0, sSource);
}



void FFTV1PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 0, 0, 0, sSource1);
}

void FFTV2PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 1, 0, 0, sSource);
}

void FFTV3PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 2, 0, 0, sSource1);
}

void FFTV4PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 3, 0, 0, sSource);
}

void FFTV5PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 4, 0, 0, sSource1);
}

void FFTV6PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 5, 0, 0, sSource);
}
		
void FFTV7PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 6, 0, 0, sSource1);
}

void FFTV8PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 7, 0, 0, sSource);
}





void IFFTH1PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 0, 1, 1, sFrequencyDomain);
}

void IFFTH2PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 1, 1, 1, sSource);
}

void IFFTH3PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 2, 1, 1, sSource1);
}

void IFFTH4PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 3, 1, 1, sSource);
}

void IFFTH5PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 4, 1, 1, sSource1);
}

void IFFTH6PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 5, 1, 1, sSource);
}
		
void IFFTH7PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 6, 1, 1, sSource1);
}

void IFFTH8PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 7, 1, 1, sSource);
}



void IFFTV1PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 0, 0, 1, sSource1);
}

void IFFTV2PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 1, 0, 1, sSource);
}

void IFFTV3PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 2, 0, 1, sSource1);
}

void IFFTV4PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 3, 0, 1, sSource);
}

void IFFTV5PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 4, 0, 1, sSource1);
}

void IFFTV6PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 5, 0, 1, sSource);
}
		
void IFFTV7PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 6, 0, 1, sSource1);
}

void IFFTV8PS(float4 pos : SV_Position, float2 texcoord : Texcoord, out float2 output : SV_Target)
{
	output = ButterflyPass(texcoord, 7, 0, 1, sSource);
}



technique ButterflyTable <enabled = true; hidden = true; timeout = 1000;>
{
	pass
	{
		VertexShader = PostProcessVS;
		PixelShader = ButterflyTablePS;
		RenderTarget = ButterflyTable;
	}
}

//Prevents ButterflyTable from being dumped from memory when not in use
technique DoNothing <enabled = true; hidden = true;>
{
	pass
	{
		VertexShader = PostProcessVS;
		PixelShader = DoNothingPS;
	}
}

technique FastFourierTransform
{
	//By default InputPS uses the Luma of the Image
	pass Input
	{
		VertexShader = PostProcessVS;
		PixelShader = InputPS;
		RenderTarget = FFTInput;
	}
#ifdef FFTONE	
	pass FFTH1
	{
		VertexShader = PostProcessVS;
		PixelShader = FFTH1PS;
		RenderTarget = Source;
	}
#endif	

#ifdef FFTTWO
	pass FFTH2
	{
		VertexShader = PostProcessVS;
		PixelShader = FFTH2PS;
		RenderTarget = Source1;
	}
#endif
	
#ifdef FFTTHREE	
	pass FFTH3
	{
		VertexShader = PostProcessVS;
		PixelShader = FFTH3PS;
		RenderTarget = Source;
	}
#endif	

#ifdef FFTFOUR
	pass FFTH4
	{
		VertexShader = PostProcessVS;
		PixelShader = FFTH4PS;
		RenderTarget = Source1;
	}
#endif

#ifdef FFTFIVE
	pass FFTH5
	{
		VertexShader = PostProcessVS;
		PixelShader = FFTH5PS;
		RenderTarget = Source;
	}
#endif

#ifdef FFTSIX	
	pass FFTH6
	{
		VertexShader = PostProcessVS;
		PixelShader = FFTH6PS;
		RenderTarget = Source1;
	}
#endif

#ifdef FFTSEVEN	
	pass FFTH7
	{
		VertexShader = PostProcessVS;
		PixelShader = FFTH7PS;
		RenderTarget = Source;
	}
#endif

#ifdef FFTEIGHT	
	pass FFTH8
	{
		VertexShader = PostProcessVS;
		PixelShader = FFTH8PS;
		RenderTarget = Source1;
	}
#endif

	pass MoveSourceToSource1
	{
		VertexShader = PostProcessVS;
		PixelShader = MoveSourceToSource1PS;
		RenderTarget = Source1;
	}
	
#ifdef FFTONE	
	pass FFTV1
	{
		VertexShader = PostProcessVS;
		PixelShader = FFTV1PS;
		RenderTarget = Source;
	}
#endif	

#ifdef FFTTWO
	pass FFTV2
	{
		VertexShader = PostProcessVS;
		PixelShader = FFTV2PS;
		RenderTarget = Source1;
	}
#endif
	
#ifdef FFTTHREE	
	pass FFTV3
	{
		VertexShader = PostProcessVS;
		PixelShader = FFTV3PS;
		RenderTarget = Source;
	}
#endif	

#ifdef FFTFOUR
	pass FFTV4
	{
		VertexShader = PostProcessVS;
		PixelShader = FFTV4PS;
		RenderTarget = Source1;
	}
#endif

#ifdef FFTFIVE
	pass FFTV5
	{
		VertexShader = PostProcessVS;
		PixelShader = FFTV5PS;
		RenderTarget = Source;
	}
#endif

#ifdef FFTSIX	
	pass FFTV6
	{
		VertexShader = PostProcessVS;
		PixelShader = FFTV6PS;
		RenderTarget = Source1;
	}
#endif

#ifdef FFTSEVEN	
	pass FFTV7
	{
		VertexShader = PostProcessVS;
		PixelShader = FFTV7PS;
		RenderTarget = Source;
	}
#endif

#ifdef FFTEIGHT	
	pass FFTV8
	{
		VertexShader = PostProcessVS;
		PixelShader = FFTV8PS;
		RenderTarget = Source1;
	}
#endif

	pass MoveToFrequencyDomain
	{
		VertexShader = PostProcessVS;
		PixelShader = MoveToFrequencyDomainPS;
		RenderTarget = FrequencyDomain;
	}


//Passes to modify the image while its in frequency domain should go here




#ifdef FFTONE	
	pass IFFTH1
	{
		VertexShader = PostProcessVS;
		PixelShader = IFFTH1PS;
		RenderTarget = Source;
	}
#endif	

#ifdef FFTTWO
	pass IFFTH2
	{
		VertexShader = PostProcessVS;
		PixelShader = IFFTH2PS;
		RenderTarget = Source1;
	}
#endif
	
#ifdef FFTTHREE	
	pass IFFTH3
	{
		VertexShader = PostProcessVS;
		PixelShader = IFFTH3PS;
		RenderTarget = Source;
	}
#endif	

#ifdef FFTFOUR
	pass IFFTH4
	{
		VertexShader = PostProcessVS;
		PixelShader = IFFTH4PS;
		RenderTarget = Source1;
	}
#endif

#ifdef FFTFIVE
	pass IFFTH5
	{
		VertexShader = PostProcessVS;
		PixelShader = IFFTH5PS;
		RenderTarget = Source;
	}
#endif

#ifdef FFTSIX	
	pass IFFTH6
	{
		VertexShader = PostProcessVS;
		PixelShader = IFFTH6PS;
		RenderTarget = Source1;
	}
#endif

#ifdef FFTSEVEN	
	pass IFFTH7
	{
		VertexShader = PostProcessVS;
		PixelShader = IFFTH7PS;
		RenderTarget = Source;
	}
#endif

#ifdef FFTEIGHT	
	pass IFFTH8
	{
		VertexShader = PostProcessVS;
		PixelShader = IFFTH8PS;
		RenderTarget = Source1;
	}
#endif

	pass MoveSourceToSource1
	{
		VertexShader = PostProcessVS;
		PixelShader = MoveSourceToSource1PS;
		RenderTarget = Source1;
	}
	
#ifdef FFTONE	
	pass IFFTV1
	{
		VertexShader = PostProcessVS;
		PixelShader = IFFTV1PS;
		RenderTarget = Source;
	}
#endif	

#ifdef FFTTWO
	pass IFFTV2
	{
		VertexShader = PostProcessVS;
		PixelShader = IFFTV2PS;
		RenderTarget = Source1;
	}
#endif
	
#ifdef FFTTHREE	
	pass IFFTV3
	{
		VertexShader = PostProcessVS;
		PixelShader = IFFTV3PS;
		RenderTarget = Source;
	}
#endif	

#ifdef FFTFOUR
	pass IFFTV4
	{
		VertexShader = PostProcessVS;
		PixelShader = IFFTV4PS;
		RenderTarget = Source1;
	}
#endif

#ifdef FFTFIVE
	pass IFFTV5
	{
		VertexShader = PostProcessVS;
		PixelShader = IFFTV5PS;
		RenderTarget = Source;
	}
#endif

#ifdef FFTSIX	
	pass IFFTV6
	{
		VertexShader = PostProcessVS;
		PixelShader = IFFTV6PS;
		RenderTarget = Source1;
	}
#endif

#ifdef FFTSEVEN	
	pass IFFTV7
	{
		VertexShader = PostProcessVS;
		PixelShader = IFFTV7PS;
		RenderTarget = Source;
	}
#endif

#ifdef FFTEIGHT	
	pass IFFTV8
	{
		VertexShader = PostProcessVS;
		PixelShader = IFFTV8PS;
		RenderTarget = Source1;
	}
#endif
	pass MoveToOutput
	{
		VertexShader = PostProcessVS;
		PixelShader = MoveToOutputPS;
		RenderTarget = FFTOutput;
	}
}
