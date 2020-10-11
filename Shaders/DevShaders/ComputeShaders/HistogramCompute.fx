/*
	Histogram made using compute shaders
	By: Lord of Lunacy
*/


#define TILE_SIZE 32
#define BIN_COUNT 256
#define SAMPLE_DISTANCE 1
#define GRAPH_HEIGHT 256
#define HORIZONTAL_TILES (uint(uint(BUFFER_WIDTH - 1) / TILE_SIZE) / SAMPLE_DISTANCE + 1)
#define VERTICAL_TILES (uint(uint(BUFFER_HEIGHT - 1) / TILE_SIZE) / SAMPLE_DISTANCE + 1)
#define TILE_COUNT uint((HORIZONTAL_TILES) * (VERTICAL_TILES))
#define MERGE_COUNT (uint((TILE_COUNT - 1) / 1024) + 1)
#define MERGE_HEIGHT (uint((TILE_COUNT - 1) / MERGE_COUNT) + 1)
#define HISTOGRAM_SCALE (((BUFFER_WIDTH * BUFFER_HEIGHT) / GRAPH_HEIGHT) / (0.05 * BIN_COUNT))


texture BackBuffer : COLOR;
texture HistogramTiles {Width = BIN_COUNT; Height = TILE_COUNT; Format = RGBA16f;};
texture Histogram {Width = BIN_COUNT; Height = 1; Format = RGBA32f;};
texture HistogramGraph {Width = BIN_COUNT; Height = GRAPH_HEIGHT; Format = RGBA8;};

storage wHistogramTiles {Texture = HistogramTiles;};
storage wHistogram {Texture = Histogram;};
storage wHistogramGraph {Texture = HistogramGraph;};

sampler sBackBuffer {Texture = BackBuffer;};
sampler sHistogramTiles {Texture = HistogramTiles;};
sampler sHistogram {Texture = Histogram;};
sampler sHistogramGraph {Texture = HistogramGraph;};


uniform float GraphSize<
	ui_type = "slider";
	ui_label = "Graph Size";
	ui_min = 1; ui_max = 4;
	ui_step = 0.001;
> = 1;		

void PostProcessVS(in uint id : SV_VertexID, out float4 position : SV_Position, out float2 texcoord : TEXCOORD)
{
	texcoord.x = (id == 2) ? 2.0 : 0.0;
	texcoord.y = (id == 1) ? 2.0 : 0.0;
	position = float4(texcoord * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
}
		
groupshared uint red[BIN_COUNT];
groupshared uint green[BIN_COUNT];
groupshared uint blue[BIN_COUNT];
groupshared uint luma[BIN_COUNT];


void HistogramTilesCS(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID)
{
	uint bin = (uint(tid.x) + (uint(tid.y) * TILE_SIZE));
	uint2 tileCoord = (id.xy / TILE_SIZE);
	uint tile = (uint(tileCoord.x) + (uint(tileCoord.y) * HORIZONTAL_TILES));
	
	if(bin < BIN_COUNT)
	{
		red[bin] = 0;
		green[bin] = 0;
		blue[bin] = 0;
		luma[bin] = 0;
	}
	//groupMemoryBarrier();
	barrier();
	
	float4 color = -1;
	
	uint2 coord = id.xy * SAMPLE_DISTANCE;

	if (all(coord.xy < uint2(BUFFER_WIDTH, BUFFER_HEIGHT))) //only extract values for real pixels
	{
		float4 color = float4(tex2Dfetch(sBackBuffer, float4(id.xy, 0, 0)).rgb * (BIN_COUNT - 1), 0);
		color.a = dot(color.rgb, 0.333333);
		
		//updating the bins		
		atomicAdd(red[ int(color.r) ], 1);
		atomicAdd(green[ uint(color.g) ], 1);
		atomicAdd(blue[ uint(color.b) ], 1);
		atomicAdd(luma[ uint(color.a) ], 1);
	}
	barrier();
	
	if (bin < BIN_COUNT)
	{
		color = float4(red[bin], green[bin], blue[bin], luma[bin]);
		tex2Dstore(wHistogramTiles, int2(bin, tile), color);
	}
}

groupshared uint4 binTotal;
void TileMergeCS(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID)
{
	if(tid.y == 0) binTotal = 0;
	barrier();
	
	uint4 color = 0;
	for(int i = 0; i < MERGE_COUNT; i++)
	{
		uint yCoord = tid.y + MERGE_HEIGHT * i;
		if(yCoord < TILE_COUNT)
		{
		color += uint4(tex2Dfetch(sHistogramTiles, float4(id.x, yCoord, 0, 0)));
		}
	}
	/*if(id.y < TILE_COUNT)
	{
		color += uint4(tex2Dfetch(sHistogramTiles, float4(id.xy, 0, 0)));
	}*/
	atomicAdd(binTotal.r, color.r);
	atomicAdd(binTotal.g, color.g);
	atomicAdd(binTotal.b, color.b);
	atomicAdd(binTotal.a, color.a);
	barrier();
	//uint level = id.y / MERGE_HEIGHT;
	
	if (tid.y == 0)
	{
		tex2Dstore(wHistogram, int2(id.x, 0), binTotal);
	}
}

groupshared uint4 heights;
groupshared uint4 graph[GRAPH_HEIGHT];	
void GraphCS(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID)
{
	if(tid.y == 0)
	{
		binTotal = tex2Dfetch(sHistogram, float4(id.x, 0, 0, 0));
	}
	barrier();
	if (tid.y == 0)
	{
		heights.r = binTotal.r / HISTOGRAM_SCALE;
	}
	else if (tid.y == 1)
	{
		heights.g = binTotal.g / HISTOGRAM_SCALE;
	}
	else if (tid.y == 2)
	{
		heights.b = binTotal.b / HISTOGRAM_SCALE;
	}
	else if (tid.y == 3)
	{
		heights.a = binTotal.a / HISTOGRAM_SCALE;
	}
	graph[tid.y] = 0;
	barrier();
	
	if (tid.y <= heights.r || tid.y <= heights.a)
	{
		graph[tid.y].r = 1;
		graph[tid.y].a = 1;
	}
	if (tid.y <= heights.g || tid.y <= heights.a)
	{
		graph[tid.y].g = 1;
		graph[tid.y].a = 1;
	}
	if (tid.y <= heights.b || tid.y <= heights.a)
	{
		graph[tid.y].b = 1;
		graph[tid.y].a = 1;
	}
	barrier();
	
	tex2Dstore(wHistogramGraph, int2(id.x, (GRAPH_HEIGHT - id.y)), float4(graph[tid.y]));
}

void GraphToBackBufferPS(float4 pos : SV_POSITION, float2 texcoord : TEXCOORD, out float4 graph : SV_TARGET)
{
	int2 coord = (texcoord / GraphSize) * int2(BUFFER_WIDTH, BUFFER_HEIGHT);
	coord.y += (256) - (BUFFER_HEIGHT / GraphSize);
	graph = tex2D(sBackBuffer, texcoord).rgba;
	float3 histogram = tex2Dfetch(sHistogramGraph, float4(coord, 0, 0));
	if(any(histogram > 0))
	{
		graph.rgb = histogram.rgb;
	}
}

technique HistogramCS
{
	pass
	{
		ComputeShader = HistogramTilesCS<TILE_SIZE, TILE_SIZE>;
		DispatchSizeX = HORIZONTAL_TILES;
		DispatchSizeY = VERTICAL_TILES;
	}
	
	pass
	{
		ComputeShader = TileMergeCS<1, MERGE_HEIGHT>;
		DispatchSizeX = BIN_COUNT;
		DispatchSizeY = 1;
	}
	
	pass
	{
		ComputeShader = GraphCS<1, GRAPH_HEIGHT>;
		DispatchSizeX = BIN_COUNT;
		DispatchSizeY = 1;
	}
	
	pass
	{
		VertexShader = PostProcessVS;
		PixelShader = GraphToBackBufferPS;
	}
}
