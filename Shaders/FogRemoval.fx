/*
Reshade Fog Removal
By: Lord of Lunacy
This shader attempts to remove fog so that affects that experience light bleeding from it can be applied,
and then reintroduce the fog over the image.
This code was inspired by the following papers:
M. J. Abbaspour, M. Yazdi, and M. Masnadi-Shirazi, “A new fast method for foggy image enhancement,” 
2016 24th Iranian Conference on Electrical Engineering (ICEE), 2016.
W. Sun, “A new single-image fog removal algorithm based on physical model,” 
Optik, vol. 124, no. 21, pp. 4770–4775, 2013.
*/

//---------------------------------------------------------------------------//
 // 	Bilateral Filter Made by mrharicot ported over to Reshade by BSD      //
 //		GitHub Link for sorce info github.com/SableRaf/Filters4Processing	  //
 // 	Shadertoy Link https://www.shadertoy.com/view/4dfGDH  Thank You.	  //
 //___________________________________________________________________________//

#include "Reshade.fxh"
#ifndef FOGREMOVAL_FILTERSIZE
#define FOGREMOVAL_FILTERSIZE 5
#endif
#define FOGREMOVAL_FILTERDISTANCE 1




uniform float STRENGTH<
	ui_type = "drag";
	ui_min = 0.0; ui_max = 1.0;
	ui_label = "Strength";
> = 1;

uniform float X<
	ui_type = "drag";
	ui_min = 0.0; ui_max = 1.0;
	ui_label = "Depth Curve";
> = 0;


uniform bool USEDEPTH<
	ui_label = "Ignore the sky";
	ui_tooltip = "Useful for shaders such as RTGI that rely on skycolor";
> = 0;

uniform int SIGMA <
	ui_type = "drag";
	ui_min = 1; ui_max = 10;
	ui_label = "SIGMA";
	ui_tooltip = "Place Holder.";
> = 5;

texture Veil {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
sampler sVeil {Texture = Veil;};

texture ErosionH <pooled = true;> {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
sampler sErosionH {Texture = ErosionH;};

texture Erosion <pooled = true;> {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
sampler sErosion {Texture = Erosion;};

texture OpenedVeilH <pooled = true;> {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
sampler sOpenedVeilH {Texture = OpenedVeilH;};

texture OpenedVeil <pooled = true;> {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
sampler sOpenedVeil {Texture = OpenedVeil;};

texture BilateralVeil {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
sampler sBilateralVeil {Texture = BilateralVeil;};





void VeilPass(float4 pos : SV_Position, float2 texcoord : TEXCOORD, out float output : SV_Target)
{
    float3 a = tex2Doffset(ReShade::BackBuffer, texcoord, int2(0, 0)).rgb;
	

	
	output = min(min(a.r, a.g), a.b);
}

void ErosionPass1(float4 pos : SV_Position, float2 texcoord : TEXCOORD, out float output : SV_Target)
{
	float minimum = 1;
	float2 coordinate = texcoord.xy;
	for(int i = -FOGREMOVAL_FILTERSIZE; i <= FOGREMOVAL_FILTERSIZE; i+= FOGREMOVAL_FILTERDISTANCE)
	{
		coordinate.x = texcoord.x + BUFFER_RCP_WIDTH * i;
		minimum = min(minimum, tex2D(sVeil, coordinate).r);
	}
	output = minimum;
}

void ErosionPass2(float4 pos : SV_Position, float2 texcoord : TEXCOORD, out float output : SV_Target)
{
	float minimum = 1;
	float2 coordinate = texcoord.xy;
	for(int j = -FOGREMOVAL_FILTERSIZE; j <= FOGREMOVAL_FILTERSIZE; j+= FOGREMOVAL_FILTERDISTANCE)
	{
		coordinate.y = texcoord.y + BUFFER_RCP_HEIGHT * j;
		minimum = min(minimum, tex2D(sErosionH, coordinate).r);
	}
	
	output = minimum;
}

void DilationPass1(float4 pos : SV_Position, float2 texcoord : TEXCOORD, out float output : SV_Target)
{
	/*float a = tex2Doffset(sErosion, texcoord, int2(0, -2)).r;
    float b = tex2Doffset(sErosion, texcoord, int2(0, -1)).r;
    float c = tex2Doffset(sErosion, texcoord, int2(-2, 0)).r;
    float d = tex2Doffset(sErosion, texcoord, int2(-1, 0)).r;
    float e = tex2Doffset(sErosion, texcoord, int2(0, 0)).r;
    float f = tex2Doffset(sErosion, texcoord, int2(1, 0)).r;
    float g = tex2Doffset(sErosion, texcoord, int2(2, 0)).r;
    float h = tex2Doffset(sErosion, texcoord, int2(0, 1)).r;
    float i = tex2Doffset(sErosion, texcoord, int2(0, 2)).r;*/
	
	float maximum = 0;
	float2 coordinate = texcoord.xy;
	for(int i = -FOGREMOVAL_FILTERSIZE; i <= FOGREMOVAL_FILTERSIZE; i+= FOGREMOVAL_FILTERDISTANCE)
	{
		coordinate.x = texcoord.x + BUFFER_RCP_WIDTH * i;
		maximum = max(maximum, tex2D(sErosion, coordinate).r);
	}
	coordinate.xy = texcoord.xy;
	
	output = maximum;
}

void DilationPass2(float4 pos : SV_Position, float2 texcoord : TEXCOORD, out float output : SV_Target)
{
	float maximum = 0;
	float2 coordinate = texcoord.xy;
	for(int j = -FOGREMOVAL_FILTERSIZE; j <= FOGREMOVAL_FILTERSIZE; j+= FOGREMOVAL_FILTERDISTANCE)
	{
		coordinate.y = texcoord.y + BUFFER_RCP_HEIGHT * j;
		maximum = max(maximum, tex2D(sOpenedVeilH, coordinate).r);
	}
	
	output = maximum;
}

#define BSIGMA 0.1
#define MSIZE 15
#define pix float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT)

float normpdf(in float x, in float sigma)
{
	return 0.39894*exp(-2*x*x/(sigma*sigma))/sigma;
}

float normpdf3(in float v, in float sigma)
{
	return 0.39894*exp(-0.5*v/(sigma*sigma))/sigma;
}
	
void BilateralFilter(float4 position : SV_Position, float2 texcoord : TEXCOORD0, out float color : SV_Target)
{
	float c = tex2D(sVeil, texcoord).r + tex2D(sOpenedVeil, texcoord).r;
	
	const int kSize = MSIZE * 0.5;	
	
	float weight[MSIZE]; 

		float final_colour;
		float Z;
		[unroll]
		for (int o =-kSize; o <= kSize; ++o)
		{
			weight[kSize+o] = normpdf(float(o), SIGMA);
		}
		
		float cc;
		float factor;
		float bZ = 1.0/normpdf(0.0, BSIGMA);
		
		[loop]
		for (int i=-kSize; i <= kSize; ++i)
		{
			for (int j=-kSize; j <= kSize; ++j)
			{
				cc = tex2D(sVeil, texcoord.xy+(float2(float(i),float(j)) * pix )).r + tex2D(sOpenedVeil, texcoord.xy+(float2(float(i),float(j)) * pix )).r;
				factor = normpdf3(cc-c, BSIGMA)*bZ*weight[kSize+j]*weight[kSize+i];
				Z += factor;
				final_colour += factor*cc;

			}
		}
		color = saturate((final_colour / Z));
		color = lerp(tex2D(sVeil, texcoord).r, tex2D(sOpenedVeil, texcoord).r, (color));
}


void ReflectivityPass(float4 pos : SV_Position, float2 texcoord : TEXCOORD, out float3 output : SV_Target)
{
	float depth = tex2D(ReShade::DepthBuffer, texcoord);
	if(USEDEPTH == 1)
	{
		if(depth >= 1) discard;
	}
	float v = tex2D(sBilateralVeil, texcoord).r;
	float strength = saturate((pow(depth, 100 * X)) * STRENGTH);
	float3 original = tex2D(ReShade::BackBuffer, texcoord).rgb;
	float originalLuma = dot(original,(0.3, 0.59, 0.11));
	output = max(((1 - strength * v.rrr)), 0.001);
	output = (original.rgb - strength * v.rrr) * rcp(output);
	float outputLuma = dot(output,(0.3, 0.59, 0.11));
	float multiplier = originalLuma * rcp(outputLuma);
	output = saturate(output);
}


void ReintroductionPass(float4 pos : SV_Position, float2 texcoord : TEXCOORD, out float3 output : SV_Target)
{
	float depth = tex2D(ReShade::DepthBuffer, texcoord);
	if(USEDEPTH == 1)
	{
		if(depth >= 1) discard;
	}
	float3 fogLevel = tex2D(sBilateralVeil, texcoord).rrr;
	float3 original = tex2D(ReShade::BackBuffer, texcoord).rgb;
	float strength = saturate((pow(depth, 100 * X)) * STRENGTH);
	output = original * (1 - strength * fogLevel) + strength * fogLevel;
}

technique FogRemoval <ui_tooltip = "Place this before shaders that you want to be rendered without fog";>
{
	pass VeilDetection
	{
		VertexShader = PostProcessVS;
		PixelShader = VeilPass;
		RenderTarget0 = Veil;
	}
	
	pass ErodeVeilHorizontal
	{
		VertexShader = PostProcessVS;
		PixelShader = ErosionPass1;
		RenderTarget0 = ErosionH;
	}
	
		pass ErodeVeilVertical
	{
		VertexShader = PostProcessVS;
		PixelShader = ErosionPass2;
		RenderTarget0 = Erosion;
	}
	
	pass OpenVeilHorizontal
	{
		VertexShader = PostProcessVS;
		PixelShader = DilationPass1;
		RenderTarget0 = OpenedVeilH;
	}
	
	pass OpenVeilVertical
	{
		VertexShader = PostProcessVS;
		PixelShader = DilationPass2;
		RenderTarget0 = OpenedVeil;
	}
	
	pass BilateralFilter
	{
		VertexShader = PostProcessVS;
		PixelShader = BilateralFilter;
		RenderTarget0 = BilateralVeil;
	}
	
	pass ReflectivityAndRemoval
	{
		VertexShader = PostProcessVS;
		PixelShader = ReflectivityPass;
	}
}

technique FogReintroduction <ui_tooltip = "Place this after the shaders you want to be rendered without fog";>
{
	pass FogReintroduction
	{
		VertexShader = PostProcessVS;
		PixelShader = ReintroductionPass;
	}
}
