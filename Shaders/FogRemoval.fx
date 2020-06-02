/*
Reshade Fog Removal
By: Lord of Lunacy
This shader attempts to remove fog so that affects that experience light bleeding from it can be applied,
and then reintroduce the fog over the image.


This code was inspired by the following paper:

B. Cai, X. X, K. Jia, C. Qing, and D. Tao, “DehazeNet: An End-to-End System for Single Image Haze Removal,”
IEEE Transactions on Image Processing, vol. 25, no. 11, pp. 5187–5198, 2016.
*/


#undef SAMPLEDISTANCE
#define SAMPLEDISTANCE 15


#define SAMPLEDISTANCE_SQUARED (SAMPLEDISTANCE*SAMPLEDISTANCE)
#define SAMPLEHEIGHT (BUFFER_HEIGHT / SAMPLEDISTANCE)
#define SAMPLEWIDTH (BUFFER_WIDTH / SAMPLEDISTANCE)
#define SAMPLECOUNT (SAMPLEHEIGHT * SAMPLEWIDTH)
#define SAMPLECOUNT_RCP (1/SAMPLECOUNT)
#define HISTOGRAMPIXELSIZE (1/255)


#include "ReShade.fxh"
	uniform float STRENGTH<
		ui_type = "drag";
		ui_min = 0.0; ui_max = 1.0;
		ui_label = "Strength";
		ui_tooltip = "Setting strength to high is known to cause bright regions to turn black before reintroduction.";
	> = 0.950;

	uniform float DEPTHCURVE<
		ui_type = "drag";
		ui_min = 0.0; ui_max = 1.0;
		ui_label = "Depth Curve";
	> = 0;
	
	uniform float REMOVALCAP<
	ui_type = "drag";
	ui_min = 0.0; ui_max = 1.0;
	ui_label = "Fog Removal Cap";
	ui_tooltip = "Prevents fog removal from trying to extract more details than can actually be removed, \n"
		"also helps preserve textures or lighting that may be detected as fog.";
	> = 0.35;
	
	uniform float2 MEDIANBOUNDS<
	ui_type = "slider";
	ui_min = 0.0; ui_max = 1.0;
	ui_label = "Average Light Levels";
	ui_tooltip = "The number to the left should correspond to the average amount of light at night, \n"
		"the number to the right should correspond to the amount of light during the day.";
	> = float2(0.2, 0.8);
	
	uniform float2 SENSITIVITYBOUNDS<
		ui_type = "slider";
		ui_min = 0.0; ui_max = 1.0;
		ui_label = "Fog Sensitivity";
		ui_tooltip = "This number adjusts how sensitive the shader is to fog, a lower number means that \n"
			"it will detect more fog in the scene, but will also be more vulnerable to false positives.\n"
			"A higher number means that it will detect less fog in the scene but will also be more \n"
			"likely to fail at detecting fog. The number on the left corresponds to the value used at night, \n"
			"while the number on the right corresponds to the value used during the day.";
	> = float2(0.2, 0.75);
	
	uniform bool USEDEPTH<
		ui_label = "Ignore the sky";
		ui_tooltip = "Useful for shaders such as RTGI that rely on skycolor";
	> = 0;
	
texture ColorAttenuation {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
sampler sColorAttenuation {Texture = ColorAttenuation;};
texture DarkChannel {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
sampler sDarkChannel {Texture = DarkChannel;};
texture Transmission {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
sampler sTransmission {Texture = Transmission;};
texture LumaHistogram {Width = 256; Height = 1; Format = R32F;};
sampler sLumaHistogram {Texture = LumaHistogram;};
texture MedianLuma {Width = 1; Height = 1; Format = R8;};
sampler sMedianLuma {Texture = MedianLuma;};


void HistogramVS(uint id : SV_VERTEXID, out float4 pos : SV_POSITION)
{
	uint xpos = id % SAMPLEWIDTH;
	uint ypos = id / SAMPLEWIDTH;
	xpos *= SAMPLEDISTANCE;
	ypos *= SAMPLEDISTANCE;
	int4 texturePos = int4(xpos, ypos, 0, 0);
	float color;
	float3 rgb = tex2Dfetch(ReShade::BackBuffer, texturePos).rgb;
	float3 luma = (0.3333, 0.3333, 0.3333);
	color = dot(rgb, luma);
	color = (color * 255 + 0.5)/256;
	pos = float4(color * 2 - 1, 0, 0, 1);
}

void HistogramPS(float4 pos : SV_POSITION, out float col : SV_TARGET )
{
	col = 1;
}

void MedianLumaPS(float4 pos : SV_Position, out float output : SV_Target0)
{
	int fifty = 0.5 * SAMPLECOUNT;
	int sum = 0;
	int i = 0;
	while (sum < fifty)
	{
		sum = sum + tex2Dfetch(sLumaHistogram, int4(i%256, 0, 0, 0));
		i++;
		if (i >= 255) sum = fifty;
	}
	output = i;
	output = output / 255;
}

void FeaturesPS(float4 pos : SV_Position, float2 texcoord : TexCoord, out float colorAttenuation : SV_Target0, out float darkChannel : SV_Target1)
{
	float3 color = tex2D(ReShade::BackBuffer, texcoord).rgb;
	float value = max(max(color.r, color.g), color.b);
	float minimum = min(min(color.r, color.g), color.b);
	float saturation = (value - minimum) / (value);
	colorAttenuation = value - saturation;
	darkChannel = 1;
	float depth = ReShade::GetLinearizedDepth(texcoord);
	float2 pixSize = tex2Dsize(ReShade::DepthBuffer, 0);
	pixSize.x = 1 / pixSize.x;
	pixSize.y = 1 / pixSize.y;
	float depthContrast = 0;
	for(int i = -2; i <= 2; i++)
	{
		float sum = 0;
		float depthSum = 0;
		for(int j = -2; j <= 2; j++)
		{
			color = tex2Doffset(ReShade::BackBuffer, texcoord, int2(i, j)).rgb;
			darkChannel = min(min(color.r, color.g), min(color.b, darkChannel));
			float2 matrixCoord;
			matrixCoord.x = texcoord.x + pixSize.x * i;
			matrixCoord.y = texcoord.y + pixSize.y * j;
			float depth1 = ReShade::GetLinearizedDepth(matrixCoord);
			float depthSubtract = depth - depth1;
			depthSum += depthSubtract * depthSubtract;
		}
		depthContrast = max(depthContrast, depthSum);
	}
	depthContrast = sqrt(0.2 * depthContrast);
	darkChannel = lerp(darkChannel, minimum, saturate(2 * depthContrast));
}

void TransmissionPS(float4 pos: SV_Position, float2 texcoord : TexCoord, out float transmission : SV_Target0)
{
	float darkChannel = tex2D(sDarkChannel, texcoord).r;
	float colorAttenuation = tex2D(sColorAttenuation, texcoord).r;
	transmission = (darkChannel / (1 - colorAttenuation));
	float median = clamp(tex2Dfetch(sMedianLuma, int4(0, 0, 0, 0)), MEDIANBOUNDS.x, MEDIANBOUNDS.y);
	float v = (median - MEDIANBOUNDS.x) * ((SENSITIVITYBOUNDS.x - SENSITIVITYBOUNDS.y) / (MEDIANBOUNDS.x - MEDIANBOUNDS.y)) + SENSITIVITYBOUNDS.x;
	transmission = saturate(transmission - v * (darkChannel + darkChannel));
	transmission = clamp(transmission * (1-v), 0, REMOVALCAP);
}

void FogRemovalPS(float4 pos: SV_Position, float2 texcoord : TexCoord, out float3 output : SV_Target0)
{
	float transmission = tex2D(sTransmission, texcoord).r;
	float depth = tex2D(ReShade::DepthBuffer, texcoord).r;
	if(USEDEPTH == 1)
	{
		if(depth >= 1) discard;
	}
	float strength = saturate((pow(depth, 100*DEPTHCURVE)) * STRENGTH);
	float3 original = tex2D(ReShade::BackBuffer, texcoord).rgb;
	float multiplier = max(((1 - strength * transmission)), 0.01);
	output = (original.rgb - strength * transmission) * rcp(multiplier);
	output = saturate(output.rgb);
}

void FogReintroductionPS(float4 pos : SV_Position, float2 texcoord : TexCoord, out float3 output : SV_Target0)
{
	float depth = tex2D(ReShade::DepthBuffer, texcoord).r;
	if(USEDEPTH == 1)
	{
		if(depth >= 1) discard;
	}
	float transmission = tex2D(sTransmission, texcoord).r;
	float3 original = tex2D(ReShade::BackBuffer, texcoord).rgb;
	float strength = saturate((pow(depth, 100 * DEPTHCURVE)) * STRENGTH);
	float multiplier = max(((1 - strength * transmission)), 0.01);
	output = original * multiplier + strength * transmission;
}

technique FogRemoval
{
	pass Histogram
	{
		PixelShader = HistogramPS;
		VertexShader = HistogramVS;
		PrimitiveTopology = POINTLIST;
		VertexCount = SAMPLECOUNT;
		RenderTarget0 = LumaHistogram;
		ClearRenderTargets = true; 
		BlendEnable = true; 
		SrcBlend = ONE; 
		DestBlend = ONE;
		BlendOp = ADD;
	}
	
	pass MedianLuma
	{
		VertexShader = PostProcessVS;
		PixelShader = MedianLumaPS;
		RenderTarget0 = MedianLuma;
		ClearRenderTargets = true;
	}
	
	pass Features
	{
		VertexShader = PostProcessVS;
		PixelShader = FeaturesPS;
		RenderTarget0 = ColorAttenuation;
		RenderTarget1 = DarkChannel;
	}
	
	pass Transmission
	{
		VertexShader = PostProcessVS;
		PixelShader = TransmissionPS;
		RenderTarget0 = Transmission;
	}
	
	pass FogRemoval
	{
		VertexShader = PostProcessVS;
		PixelShader = FogRemovalPS;
	}
}

technique FogReintroduction
{
	pass Reintroduction
	{
		VertexShader = PostProcessVS;
		PixelShader = FogReintroductionPS;
	}
}
