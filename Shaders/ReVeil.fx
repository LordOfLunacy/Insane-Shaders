/*
ReVeil for Reshade
By: Lord of Lunacy


This shader attempts to remove fog using a dark channel prior technique that has been
refined using 2 passes over iterative guided Wiener filters ran on the image dark channel.

The purpose of the Wiener filters is to minimize the root mean square error between
the given dark channel, and the expected dark channel, making this aspect of the
image more accurate. These variables used to guide these filters are the image
variance, skewness, and kurtosis of local neighborhoods of pixels.

The airlight of the image is estimated by using the refined local dark channel mean, and 
adding to it a set multiple of the (refined) standard deviations in the image.

Koschmeider's airlight equation is then used to remove the veil from the image, and the inverse
is applied to reverse this affect, blending any new image components with the fog.


This method was adapted from the following paper:
Gibson, Kristofor & Nguyen, Truong. (2013). Fast single image fog removal using the adaptive Wiener filter.
2013 IEEE International Conference on Image Processing, ICIP 2013 - Proceedings. 714-718. 10.1109/ICIP.2013.6738147. 
*/

#ifndef WINDOW_SIZE
	#define WINDOW_SIZE 5
#endif

#if WINDOW_SIZE > 1023
	#undef WINDOW_SIZE
	#define WINDOW_SIZE 1023
#endif

#ifndef SECOND_PASS
	#define SECOND_PASS 0
#endif

#ifndef USE_KURTOSIS
	#define USE_KURTOSIS 1
#endif

#ifndef RESHADE_DEPTH_INPUT_IS_UPSIDE_DOWN
	#define RESHADE_DEPTH_INPUT_IS_UPSIDE_DOWN 0
#endif
#ifndef RESHADE_DEPTH_INPUT_IS_REVERSED
	#define RESHADE_DEPTH_INPUT_IS_REVERSED 0
#endif
#ifndef RESHADE_DEPTH_INPUT_IS_LOGARITHMIC
	#define RESHADE_DEPTH_INPUT_IS_LOGARITHMIC 0
#endif

#ifndef RESHADE_DEPTH_MULTIPLIER
	#define RESHADE_DEPTH_MULTIPLIER 1
#endif
#ifndef RESHADE_DEPTH_LINEARIZATION_FAR_PLANE
	#define RESHADE_DEPTH_LINEARIZATION_FAR_PLANE 1000.0
#endif

// Above 1 expands coordinates, below 1 contracts and 1 is equal to no scaling on any axis
#ifndef RESHADE_DEPTH_INPUT_Y_SCALE
	#define RESHADE_DEPTH_INPUT_Y_SCALE 1
#endif
#ifndef RESHADE_DEPTH_INPUT_X_SCALE
	#define RESHADE_DEPTH_INPUT_X_SCALE 1
#endif
// An offset to add to the Y coordinate, (+) = move up, (-) = move down
#ifndef RESHADE_DEPTH_INPUT_Y_OFFSET
	#define RESHADE_DEPTH_INPUT_Y_OFFSET 0
#endif
// An offset to add to the X coordinate, (+) = move right, (-) = move left
#ifndef RESHADE_DEPTH_INPUT_X_OFFSET
	#define RESHADE_DEPTH_INPUT_X_OFFSET 0
#endif

#define WINDOW_SIZE_SQUARED (WINDOW_SIZE * WINDOW_SIZE)


#define CONST_LOG2(x) (\
    (uint((x) & 0xAAAAAAAA) != 0) | \
    (uint(((x) & 0xFFFF0000) != 0) << 4) | \
    (uint(((x) & 0xFF00FF00) != 0) << 3) | \
    (uint(((x) & 0xF0F0F0F0) != 0) << 2) | \
    (uint(((x) & 0xCCCCCCCC) != 0) << 1))
	
#define BIT2_LOG2(x) ( (x) | (x) >> 1)
#define BIT4_LOG2(x) ( BIT2_LOG2(x) | BIT2_LOG2(x) >> 2)
#define BIT8_LOG2(x) ( BIT4_LOG2(x) | BIT4_LOG2(x) >> 4)
#define BIT16_LOG2(x) ( BIT8_LOG2(x) | BIT8_LOG2(x) >> 8)

#define FOGREMOVAL_LOG2(x) (CONST_LOG2( (BIT16_LOG2(x) >> 1) + 1))
	    
	

#define FOGREMOVAL_MAX(a, b) (int((a) > (b)) * (a) + int((b) > (a)) * (b))

#define FOGREMOVAL_GET_MAX_MIP(w, h) \
(FOGREMOVAL_LOG2((FOGREMOVAL_MAX((w), (h))) + 1))

#define MAX_MIP (FOGREMOVAL_GET_MAX_MIP(BUFFER_WIDTH * 2 - 1, BUFFER_HEIGHT * 2 - 1))



texture BackBuffer : COLOR;
texture DepthBuffer : DEPTH;
texture DarkChannel {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
texture MeanAndVariance {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RG32f;};
texture Mean {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16f;};
texture Variance {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16f; MipLevels = MAX_MIP;};
texture Skewness0 {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R32f;};
texture Skewness1 {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R32f; MipLevels = MAX_MIP;};
texture Airlight {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
texture Transmission {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
texture FogRemoved {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16f;};
texture TruncatedPrecision {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16f;};


sampler sBackBuffer {Texture = BackBuffer;};
sampler sDepthBuffer {Texture = DepthBuffer;};
sampler sDarkChannel {Texture = DarkChannel;};
sampler sMeanAndVariance {Texture = MeanAndVariance;};
sampler sMean {Texture = Mean;};
sampler sVariance {Texture = Variance;};
sampler sSkewness0 {Texture = Skewness0;};
sampler sSkewness1 {Texture = Skewness1;};
sampler sTransmission {Texture = Transmission;};
sampler sAirlight {Texture = Airlight;};
sampler sTruncatedPrecision {Texture = TruncatedPrecision;};
sampler sFogRemoved {Texture = FogRemoved;};

#if USE_KURTOSIS != 0
	texture Kurtosis0 {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R32f;};
	texture Kurtosis1 {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R32f; MipLevels = MAX_MIP;};
	sampler sKurtosis0 {Texture = Kurtosis0;};
	sampler sKurtosis1 {Texture = Kurtosis1;};
#endif

uniform float StandardDeviations<
	ui_type = "slider";
	ui_label = "Airlight Standard Deviations";
	ui_tooltip = "How many standard deviations are added to the dark channel mean to approximate\n"
				"the airlight value.";
	ui_min = 0; ui_max = 60;
> = 30;

uniform bool IgnoreSky<
	ui_label = "Ignore Sky";
> = 1;

	float GetLinearizedDepth(float2 texcoord)
	{
#if RESHADE_DEPTH_INPUT_IS_UPSIDE_DOWN
		texcoord.y = 1.0 - texcoord.y;
#endif
		texcoord.x /= RESHADE_DEPTH_INPUT_X_SCALE;
		texcoord.y /= RESHADE_DEPTH_INPUT_Y_SCALE;
		texcoord.x -= RESHADE_DEPTH_INPUT_X_OFFSET / 2.000000001;
		texcoord.y += RESHADE_DEPTH_INPUT_Y_OFFSET / 2.000000001;
		float depth = tex2Dlod(sDepthBuffer, float4(texcoord, 0, 0)).x * RESHADE_DEPTH_MULTIPLIER;

#if RESHADE_DEPTH_INPUT_IS_LOGARITHMIC
		const float C = 0.01;
		depth = (exp(depth * log(C + 1.0)) - 1.0) / C;
#endif
#if RESHADE_DEPTH_INPUT_IS_REVERSED
		depth = 1.0 - depth;
#endif
		const float N = 1.0;
		depth /= RESHADE_DEPTH_LINEARIZATION_FAR_PLANE - depth * (RESHADE_DEPTH_LINEARIZATION_FAR_PLANE - N);

		return depth;
	}



// Vertex shader generating a triangle covering the entire screen
void PostProcessVS(in uint id : SV_VertexID, out float4 position : SV_Position, out float2 texcoord : TEXCOORD)
{
	texcoord.x = (id == 2) ? 2.0 : 0.0;
	texcoord.y = (id == 1) ? 2.0 : 0.0;
	position = float4(texcoord * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
}

void DarkChannelPS(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float darkChannel : SV_TARGET0)
{
	float3 color = tex2D(sBackBuffer, texcoord).rgb;
	darkChannel = min(min(color.r, color.g), color.b);
}

void DarkChannelPS1(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float darkChannel : SV_TARGET0)
{
	float3 color = tex2D(sFogRemoved, texcoord).rgb;
	darkChannel = min(min(color.r, color.g), color.b);
}

#if USE_KURTOSIS != 0
void MeanAndVariancePS0(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float2 meanAndVariance : SV_TARGET0, out float skewness : SV_TARGET1, out float kurtosis : SV_TARGET2)
#else
void MeanAndVariancePS0(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float2 meanAndVariance : SV_TARGET0, out float skewness : SV_TARGET1)
#endif
{
	float darkChannel;
	float sum = 0;
	float squaredSum = 0;
	float cubedSum = 0;
	float quadSum = 0;
	[unroll]
	for(int i = -(WINDOW_SIZE / 2); i < ((WINDOW_SIZE + 1) / 2); i++)
	{
			float2 offset = float2(i * BUFFER_RCP_WIDTH, 0);
			darkChannel = tex2D(sDarkChannel, texcoord + offset).r;
			float darkChannelSquared = darkChannel * darkChannel;
			float darkChannelCubed = darkChannelSquared * darkChannel;
			sum += darkChannel;
			squaredSum += darkChannelSquared;
			cubedSum += darkChannelCubed;
#if USE_KURTOSIS != 0
			quadSum += darkChannelCubed * darkChannel;
#endif
			
	}
	meanAndVariance = float2(sum, squaredSum);
	skewness = cubedSum;
}

#if USE_KURTOSIS != 0
void MeanAndVariancePS1(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float mean : SV_TARGET0, out float variance : SV_TARGET1, out float skewness : SV_TARGET2, out float kurtosis : SV_TARGET3)
#else
void MeanAndVariancePS1(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float mean : SV_TARGET0, out float variance : SV_TARGET1, out float skewness : SV_TARGET2)
#endif
{
	float2 meanAndVariance;
	float sum = 0;
	float squaredSum = 0;
	float cubedSum = 0;
	float quadSum = 0;
	[unroll]
	for(int i = -(WINDOW_SIZE / 2); i < ((WINDOW_SIZE + 1) / 2); i++)
	{
			float2 offset = float2(0, i * BUFFER_RCP_HEIGHT);
			meanAndVariance = tex2D(sMeanAndVariance, texcoord + offset).rg;
			sum += meanAndVariance.r;
			squaredSum += meanAndVariance.g;
			cubedSum += tex2D(sSkewness0, texcoord + offset).r;
#if USE_KURTOSIS != 0
			quadSum += tex2D(sKurtosis0, texcoord + offset).r;
#endif
	}
	float sumSquared = sum * sum;
	float sumCubed = sumSquared * sum;
	float sumQuad = sumCubed * sum;
	
	mean = sum / WINDOW_SIZE_SQUARED;
	variance = (squaredSum - ((sumSquared) / WINDOW_SIZE_SQUARED));
	variance /= WINDOW_SIZE_SQUARED;
	skewness = (cubedSum - ((sumCubed) / (WINDOW_SIZE_SQUARED)));
	skewness /= WINDOW_SIZE_SQUARED * pow(variance, 1.5);
#if USE_KURTOSIS != 0
	kurtosis = (quadSum - (sumQuad) / (WINDOW_SIZE_SQUARED));
	kurtosis /= WINDOW_SIZE_SQUARED * variance * variance;
#endif
}

#if USE_KURTOSIS != 0
void MeanAndVariancePS2(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float variance : SV_TARGET0, out float skewness : SV_TARGET1, out float kurtosis : SV_TARGET2)
#else
void MeanAndVariancePS2(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float variance : SV_TARGET0, out float skewness : SV_TARGET1)
#endif
{
	float2 meanAndVariance;
	float sum = 0;
	float squaredSum = 0;
	float cubedSum = 0;
	float quadSum = 0;
	[unroll]
	for(int i = -(WINDOW_SIZE / 2); i < ((WINDOW_SIZE + 1) / 2); i++)
	{
			float2 offset = float2(0, i * BUFFER_RCP_HEIGHT);
			meanAndVariance = tex2D(sMeanAndVariance, texcoord + offset).rg;
			sum += meanAndVariance.r;
			squaredSum += meanAndVariance.g;
			cubedSum += tex2D(sSkewness0, texcoord + offset).r;
#if USE_KURTOSIS != 0
			quadSum += tex2D(sKurtosis0, texcoord + offset).r;
#endif
	}
	float sumSquared = sum * sum;
	float sumCubed = sumSquared * sum;
	float sumQuad = sumCubed * sum;
	
	float mean = sum / WINDOW_SIZE_SQUARED;
	variance = (squaredSum - ((sumSquared) / WINDOW_SIZE_SQUARED));
	variance /= WINDOW_SIZE_SQUARED;
	skewness = (cubedSum - ((sumCubed) / (WINDOW_SIZE_SQUARED)));
	skewness /= WINDOW_SIZE_SQUARED * pow(variance, 1.5);
#if USE_KURTOSIS != 0
	kurtosis = (quadSum - (sumQuad) / (WINDOW_SIZE_SQUARED));
	kurtosis /= WINDOW_SIZE_SQUARED * variance * variance;
#endif
}

void WienerFilterPS(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float transmission : SV_TARGET0, out float airlight : SV_TARGET1)
{
	float mean = tex2D(sMean, texcoord).r;
	float variance = tex2D(sVariance, texcoord).r;
	float noise = tex2Dlod(sVariance, float4(texcoord, 0, MAX_MIP - 1)).r;
	float darkChannel = tex2D(sDarkChannel, texcoord).r;
	float skewness = tex2D(sSkewness1, texcoord).r;
	float averageSkewness = tex2Dlod(sSkewness1, float4(texcoord, 0, MAX_MIP - 1)).r;
	
#if USE_KURTOSIS != 0
	float kurtosis = tex2D(sKurtosis1, texcoord).r;
	float averageKurtosis = tex2Dlod(sKurtosis1, float4(texcoord, 0, MAX_MIP - 1)).r;
	
	float skewnessFilter = (max((kurtosis - averageKurtosis), 0) / kurtosis) * (skewness - averageSkewness);
	skewness += saturate(skewnessFilter);
#endif
	skewness = saturate(skewness);
	float varianceFilter = (max((skewness - averageSkewness), 0) / skewness) * (variance - noise);
	variance += saturate(varianceFilter);
	variance = saturate(variance);
	
	float filter = saturate((max((variance - noise), 0) / variance) * (darkChannel - mean));
	float veil = saturate(mean + filter);
	//filter = ((variance - noise) / variance) * (darkChannel - mean);
	//mean += filter;
	
	airlight = max(saturate(veil + sqrt(variance) * StandardDeviations), 0.05);
	transmission = saturate(1 - (veil * darkChannel) / airlight);

}

void FogRemovalPS(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float4 fogRemoved : SV_TARGET0)
{
	float airlight = tex2D(sAirlight, texcoord).r;
	float transmission = max((tex2D(sTransmission, texcoord).r), 0.05);
	float3 color = tex2D(sBackBuffer, texcoord).rgb;
	fogRemoved = float4(((color - airlight) / transmission) + airlight, 1);

}


void OutputToBackbufferPS(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float4 fogRemoved : SV_TARGET0)
{
	if(IgnoreSky && GetLinearizedDepth(texcoord) >= 1)
	{
		fogRemoved = float4(tex2D(sBackBuffer, texcoord).rgb, 0);
	}
	else fogRemoved = float4(tex2D(sFogRemoved, texcoord).rgb, 1);
	//fogRemoved = log(2.78 * (1 - tex2D(sTransmission, texcoord).rrrr));
}

void TruncatedPrecisionPS(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float4 truncatedPrecision : SV_TARGET0)
{
	float3 color = tex2D(sBackBuffer, texcoord).rgb;
	float3 fogRemoved = tex2D(sFogRemoved, texcoord).rgb;
	truncatedPrecision = float4(fogRemoved - color, 1);
}
	

void FogReintroductionPS(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float4 fogReintroduced : SV_TARGET0)
{
	float airlight = tex2D(sAirlight, texcoord).r;
	float transmission = max((tex2D(sTransmission, texcoord).r), 0.05);
	float3 color = tex2D(sBackBuffer, texcoord).rgb + tex2D(sTruncatedPrecision, texcoord).rgb;
	if(tex2D(sBackBuffer, texcoord).a == 0)
	{
		fogReintroduced = float4(color, 1);
	}
	fogReintroduced = float4(((color - airlight) * transmission) + airlight, 1);
	//fogReintroduced = lerp(color, tex2D(sAirlight, texcoord).rgb, tex2D(sTransmission, texcoord).r);
}

		


technique Veil_B_Gone<ui_tooltip = "Place this shader technique before any effects you wish to be placed behind the image veil.\n"
	"Veil_B_Back needs to be ran after this technique to reintroduce the image veil.";>
{
	pass DarkChannel
	{
		VertexShader = PostProcessVS;
		PixelShader = DarkChannelPS;
		RenderTarget0 = DarkChannel;
	}
	
	pass MeanAndVariance
	{
		VertexShader = PostProcessVS;
		PixelShader = MeanAndVariancePS0;
		RenderTarget0 = MeanAndVariance;
		RenderTarget1 = Skewness0;
#if USE_KURTOSIS != 0
		RenderTarget2 = Kurtosis0;
#endif
	}
	
	pass MeanAndVariance
	{
		VertexShader = PostProcessVS;
		PixelShader = MeanAndVariancePS1;
		RenderTarget0 = Mean;
		RenderTarget1 = Variance;
		RenderTarget2 = Skewness1;
#if USE_KURTOSIS != 0
		RenderTarget3 = Kurtosis1;
#endif
	}
	
	pass WienerFilter
	{
		VertexShader = PostProcessVS;
		PixelShader = WienerFilterPS;
		RenderTarget0 = Transmission;
		RenderTarget1 = Airlight;
	}
	
	pass FogRemoval
	{
		VertexShader = PostProcessVS;
		PixelShader = FogRemovalPS;
		RenderTarget = FogRemoved;
	}
	
#if SECOND_PASS != 0
	
	pass DarkChannel
	{
		VertexShader = PostProcessVS;
		PixelShader = DarkChannelPS1;
		RenderTarget0 = DarkChannel;
	}
	
	pass MeanAndVariance
	{
		VertexShader = PostProcessVS;
		PixelShader = MeanAndVariancePS0;
		RenderTarget0 = MeanAndVariance;
		RenderTarget1 = Skewness0;
#if USE_KURTOSIS != 0
		RenderTarget2 = Kurtosis0;
#endif
	}
	
	pass MeanAndVariance
	{
		VertexShader = PostProcessVS;
		PixelShader = MeanAndVariancePS2;
		RenderTarget0 = Variance;
		RenderTarget1 = Skewness1;
#if USE_KURTOSIS != 0
		RenderTarget2 = Kurtosis1;
#endif
	}
	
	pass WienerFilter
	{
		VertexShader = PostProcessVS;
		PixelShader = WienerFilterPS;
		RenderTarget0 = Transmission;
		RenderTarget1 = Airlight;
	}
	
	pass FogRemoval
	{
		VertexShader = PostProcessVS;
		PixelShader = FogRemovalPS;
		RenderTarget = FogRemoved;
	}
#endif
	
	pass BackBuffer
	{
		VertexShader = PostProcessVS;
		PixelShader = OutputToBackbufferPS;
	}
	
	pass TruncatedPrecision
	{
		VertexShader = PostProcessVS;
		PixelShader = TruncatedPrecisionPS;
		RenderTarget = TruncatedPrecision;
	}
}

technique Veil_B_Back<ui_tooltip = "Place this shader technique after Veil_B_Gone and any shaders you want to be veiled.";>
{
	pass FogReintroduction
	{
		VertexShader = PostProcessVS;
		PixelShader = FogReintroductionPS;
	}
}
