/*
Reshade Fog Removal
By: Lord of Lunacy

This shader attempts to remove fog so that affects that experience light bleeding from it can be applied,
and then reintroduce the fog over the image.



This code was inspired by the following paper:

B. Cai, X. Xu, K. Jia, C. Qing, and D. Tao, “DehazeNet: An End-to-End System for Single Image Haze Removal,”
IEEE Transactions on Image Processing, vol. 25, no. 11, pp. 5187–5198, 2016.
*/




#include "ReShade.fxh"
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

	uniform float K<
		ui_type = "drag";
		ui_min = 0.0; ui_max = 1.0;
		ui_label = "K-Level";
		ui_tooltip = "Make sure this feature is not set too high or too low" ;
	> = 0.3;


	uniform bool USEDEPTH<
		ui_label = "Ignore the sky";
		ui_tooltip = "Useful for shaders such as RTGI that rely on skycolor";
	> = 0;
texture ColorAttenuation {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
sampler sColorAttenuation {Texture = ColorAttenuation;};
texture HueDisparity {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
sampler sHueDisparity {Texture = HueDisparity;};
texture DarkChannel {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
sampler sDarkChannel {Texture = DarkChannel;};
texture MaxContrast {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
sampler sMaxContrast {Texture = MaxContrast;};
texture GaussianH {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
sampler sGaussianH {Texture = GaussianH;};
texture Transmission {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
sampler sTransmission {Texture = Transmission;};



float Hue(float3 color)
{
	float alpha = color.r - 0.5 * (color.g + color.b);
	float beta = 0.8660254 * (color.g - color.b);
	return atan(beta/alpha);
}

float colorToLuma(float3 color)
{
	return dot(color, (0.333, 0.333, 0.333)) * 3;
}

void FeaturesPS(float4 pos : SV_Position, float2 texcoord : TexCoord, out float colorAttenuation : SV_Target0, out float hueDisparity : SV_Target1, out float darkChannel : SV_Target2, out float maxContrast : SV_Target3)
{
	float3 color = tex2D(ReShade::BackBuffer, texcoord).rgb;
	float value = max(max(color.r, color.g), color.b);
	float minimum = min(min(color.r, color.g), color.b);
	float saturation = (value - minimum) / rcp(value);
	colorAttenuation = value - saturation;
	float3 semiInverse;
	semiInverse.r = max(color.r, 1 - color.r);
	semiInverse.g = max(color.g, 1 - color.g);
	semiInverse.b = max(color.b, 1 - color.b);
	float hue = Hue(color);
	float semiHue = Hue(semiInverse);
	hueDisparity = semiHue - hue;
	darkChannel = 1;
	float luma = colorToLuma(color);
	float luma1;
	float sum;
	maxContrast = 0;
	for(int i = -2; i <= 2; i++)
	{
		sum = 0;
		for(int j = -2; j <= 2; j++)
		{
			color = tex2Doffset(ReShade::BackBuffer, texcoord, int2(i, j)).rgb;
			darkChannel = min(min(color.r, color.g), min(color.b, darkChannel));
			luma1 = colorToLuma(color);
			float subtract = luma - luma1;
			sum += (subtract * subtract);
		}
		maxContrast = max(maxContrast, sum);
	}
	maxContrast = sqrt(0.2 * maxContrast);
	
}

void GaussianHPS(float4 pos: SV_Position, float2 texcoord : TexCoord, out float gaussianH : SV_Target0)
{
	gaussianH = 0;
	static const float kernel[5] = {0.187691, 0.206038, 0.212543, 0.206038, 0.187691};
	for (int i = -2; i <= 2; i++)
	{
		gaussianH += tex2Doffset(sMaxContrast, texcoord, int2(i, 0)).r * kernel[i + 2];
	}
}

void GaussianVPS(float4 pos: SV_Position, float2 texcoord : TexCoord, out float gaussianV : SV_Target0)
{
	gaussianV = 0;
	static const float kernel[5] = {0.187691, 0.206038, 0.212543, 0.206038, 0.187691};
	for (int i = -2; i <= 2; i++)
	{
		gaussianV += tex2Doffset(sGaussianH, texcoord, int2(0, i)).r * kernel[i + 2];
	}
}

void TransmissionPS(float4 pos: SV_Position, float2 texcoord : TexCoord, out float transmission : SV_Target0)
{
	float maxContrast = tex2D(sMaxContrast, texcoord).r;
	//float maxContrast = e;
	float darkChannel = tex2D(sDarkChannel, texcoord).r;
	float colorAttenuation = tex2D(sColorAttenuation, texcoord).r;
	transmission = (darkChannel * (1-colorAttenuation) * rcp(colorAttenuation));
	transmission += 2 * maxContrast;
	//float transmission1 = saturate(transmission - tex2D(sHueDisparity, texcoord));
	//transmission += transmission1;
	float k = K * (exp(1 - ReShade::GetLinearizedDepth(texcoord)));
	transmission = saturate(darkChannel - K * saturate(transmission));

}
void FogRemovalPS(float4 pos: SV_Position, float2 texcoord : TexCoord, out float3 output : SV_Target0)
{
	float transmission = tex2D(sTransmission, texcoord).r;
	float depth = tex2D(ReShade::DepthBuffer, texcoord).r;
	if(USEDEPTH == 1)
	{
		if(depth >= 1) discard;
	}
	float strength = saturate((pow(depth, 100*X)) * STRENGTH);
	float3 original = tex2D(ReShade::BackBuffer, texcoord).rgb;
	float multiplier = max(((1 - strength * transmission)), 0.001);
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
	float strength = saturate((pow(depth, 100 * X)) * STRENGTH);
	float multiplier = max(((1 - strength * transmission)), 0.001);
	output = original * multiplier + strength * transmission;
}

technique FogRemovalElectricBoogaloo
{
	pass Features
	{
		VertexShader = PostProcessVS;
		PixelShader = FeaturesPS;
		RenderTarget0 = ColorAttenuation;
		RenderTarget1 = HueDisparity;
		RenderTarget2 = DarkChannel;
		RenderTarget3 = MaxContrast;
	}
	
	pass GaussianH
	{
		VertexShader = PostProcessVS;
		PixelShader = GaussianHPS;
		RenderTarget0 = GaussianH;
	}
	
	pass GaussianV
	{
		VertexShader = PostProcessVS;
		PixelShader = GaussianVPS;
		RenderTarget0 = MaxContrast;
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
