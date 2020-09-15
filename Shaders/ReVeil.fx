/*
ReVeil for Reshade
By: Lord of Lunacy
This shader attempts to remove fog using a dark channel prior technique that has been
refined through deconvolution with a 2 pass guided Wiener filter.

This method was adapted from the following paper:
Gibson, Kristofor & Nguyen, Truong. (2013). Fast single image fog removal using the adaptive Wiener filter.
2013 IEEE International Conference on Image Processing, ICIP 2013 - Proceedings. 714-718. 10.1109/ICIP.2013.6738147. 
*/

#ifndef WINDOW_SIZE
	#define WINDOW_SIZE 32
#endif

#if WINDOW_SIZE > 1023
	#undef WINDOW_SIZE
	#define WINDOW_SIZE 1023
#endif

#ifndef SECOND_PASS
	#define SECOND_PASS 1
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
texture DarkChannel {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
texture MeanAndVariance {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RG32f;};
texture Mean {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R32f;};
texture Variance {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R32f; MipLevels = MAX_MIP;};
texture Airlight {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16f;};
texture Noise {Width = 1; Height = 1; Format = R16f;};
texture Transmission {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16f;};
texture FogRemoved {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16f;};
texture TruncatedPrecision {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16f;};

sampler sBackBuffer {Texture = BackBuffer;};
sampler sDarkChannel {Texture = DarkChannel;};
sampler sMeanAndVariance {Texture = MeanAndVariance;};
sampler sMean {Texture = Mean;};
sampler sVariance {Texture = Variance;};
sampler sNoise {Texture = Noise;};
sampler sTransmission {Texture = Transmission;};
sampler sAirlight {Texture = Airlight;};
sampler sTruncatedPrecision {Texture = TruncatedPrecision;};
sampler sFogRemoved {Texture = FogRemoved;};

uniform float StandardDeviations<
	ui_type = "slider";
	ui_label = "Airlight Standard Deviations";
	ui_tooltip = "How many standard deviations are added to the dark channel mean to approximate\n"
				"the airlight value.";
	ui_min = 0; ui_max = 60;
> = 20;


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

void MeanAndVariancePS0(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float2 meanAndVariance : SV_TARGET0)
{
	float darkChannel;
	float sum = 0;
	float squaredSum = 0;
	[unroll]
	for(int i = -(WINDOW_SIZE / 2); i < ((WINDOW_SIZE + 1) / 2); i++)
	{
			float2 offset = float2(i * BUFFER_RCP_WIDTH, 0);
			darkChannel = tex2D(sDarkChannel, texcoord + offset).r;
			sum += darkChannel;
			squaredSum += darkChannel * darkChannel;
	}
	meanAndVariance = float2(sum, squaredSum);
}

void MeanAndVariancePS1(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float mean : SV_TARGET0, out float variance : SV_TARGET1)
{
	float2 meanAndVariance;
	float sum = 0;
	float squaredSum = 0;
	[unroll]
	for(int i = -(WINDOW_SIZE / 2); i < ((WINDOW_SIZE + 1) / 2); i++)
	{
			float2 offset = float2(0, i * BUFFER_RCP_HEIGHT);
			meanAndVariance = tex2D(sMeanAndVariance, texcoord + offset).rg;
			sum += meanAndVariance.r;
			squaredSum += meanAndVariance.g;
	}
	mean = sum / WINDOW_SIZE_SQUARED;
	variance = (squaredSum - ((sum * sum) / WINDOW_SIZE_SQUARED));
	//variance = (squaredSum - 2 * mean * sum + WINDOW_SIZE_SQUARED * (mean * mean));
	variance /= WINDOW_SIZE_SQUARED;
}

void MeanAndVariancePS2(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float variance : SV_TARGET0)
{
	float2 meanAndVariance;
	float sum = 0;
	float squaredSum = 0;
	[unroll]
	for(int i = -(WINDOW_SIZE / 2); i < ((WINDOW_SIZE + 1) / 2); i++)
	{
			float2 offset = float2(0, i * BUFFER_RCP_HEIGHT);
			meanAndVariance = tex2D(sMeanAndVariance, texcoord + offset).rg;
			sum += meanAndVariance.r;
			squaredSum += meanAndVariance.g;
	}
	float mean = sum / WINDOW_SIZE_SQUARED;
	variance = (squaredSum - ((sum * sum) / WINDOW_SIZE_SQUARED));
	//variance = (squaredSum - 2 * mean * sum + WINDOW_SIZE_SQUARED * (mean * mean));
	variance /= WINDOW_SIZE_SQUARED;
}

void NoisePS(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float noise : SV_TARGET0)
{
	noise = tex2Dlod(sVariance, float4(0.5, 0.5, 0, MAX_MIP - 1)).r;
}

void WienerFilterPS(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float transmission : SV_TARGET0, out float airlight : SV_TARGET1)
{
	float mean = tex2D(sMean, texcoord).r;
	float variance = tex2D(sVariance, texcoord).r;
	float noise = tex2Dfetch(sNoise, float4(0, 0, 0, 0)).r;
	float darkChannel = tex2D(sDarkChannel, texcoord).r;
	
	float filter = ((min((variance - noise), 0) / variance) * (darkChannel - mean));
	float veil = mean + filter;
	airlight = saturate(mean + sqrt(variance) * StandardDeviations);
	//airlight = tex2D(sAirlightTest, float4(0, 0, 0, 0)).r;
	//airlight /= 2;
	transmission = (1 - (veil / airlight));
	transmission = saturate(1 - (veil * mean) / airlight);

}

void FogRemovalPS(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float4 fogRemoved : SV_TARGET0)
{
	float airlight = tex2D(sAirlight, texcoord).r;
	float transmission = max((tex2D(sTransmission, texcoord).r), 0.01);
	float3 color = tex2D(sBackBuffer, texcoord).rgb;
	fogRemoved = float4(((color - airlight) / transmission) + airlight, 1);
}


void OutputToBackbufferPS(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float4 fogRemoved : SV_TARGET0)
{
	fogRemoved = float4(tex2D(sFogRemoved, texcoord).rgb, 1);
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
	float transmission = max((tex2D(sTransmission, texcoord).r), 0.01);
	float3 color = tex2D(sBackBuffer, texcoord).rgb + tex2D(sTruncatedPrecision, texcoord).rgb;
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
	}
	
	pass MeanAndVariance
	{
		VertexShader = PostProcessVS;
		PixelShader = MeanAndVariancePS1;
		RenderTarget0 = Mean;
		RenderTarget1 = Variance;
	}
	
	pass Noise
	{
		VertexShader = PostProcessVS;
		PixelShader = NoisePS;
		RenderTarget = Noise;
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
	}
	
	pass MeanAndVariance
	{
		VertexShader = PostProcessVS;
		PixelShader = MeanAndVariancePS2;
		RenderTarget0 = Variance;
	}
	
	pass Noise
	{
		VertexShader = PostProcessVS;
		PixelShader = NoisePS;
		RenderTarget0 = Noise;
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
