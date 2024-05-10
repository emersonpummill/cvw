module cachelfsr #(parameter WIDTH = 4, SETLEN = 9, OFFSETLEN = 5, NUMLINES = 128) (
	 input logic  clk, reset, FlushStage, CacheEn,
	 input logic [WIDTH-1:0] HitWay, ValidWay,
	 input logic [SETLEN-1:0] CacheSetData, CacheSetTag, PAdr,
	 input logic LRUWriteEn, SetValid, ClearValid, InvalidateCache,
	 output logic [WIDTH-1:0] VictimWay);
   logic [WIDTH-1:0] next;
   localparam  LOGNUMWAYS = $clog2(WIDTH);
   localparam  LFSRWIDTH = LOGNUMWAYS + 2;

   logic [WIDTH-2:0] LRUMemory [NUMLINES-1:0];

   logic [LOGNUMWAYS-1:0] HitWayEncoded, Way;
   logic   AllValid, lfsrEN;
   assign lfsrEN = ~FlushStage & LRUWriteEn;
   logic [WIDTH-1:0] val, curr;

   assign val[WIDTH-1:1] = 'b0;

   assign val[0] = 1;


   if(WIDTH==3) assign next[WIDTH-1] = curr[0] ^ curr[2];

   if(WIDTH==4) assign next[WIDTH-1] = curr[0] ^ curr[3];

   if(WIDTH==5) assign next[WIDTH-1] = curr[0] ^ curr[2] ^ curr[3] ^ curr[4];

   if(WIDTH==6) assign next[WIDTH-1] = curr[1] ^ curr[2] ^ curr[4] ^ curr[5];

   if(WIDTH==7) assign next[WIDTH-1] = curr[0] ^ curr[3] ^ curr[5] ^ curr[6];

   if(WIDTH==8) assign next[WIDTH-1] = curr[1] ^ curr[2] ^ curr[5] ^ curr[7];

   if(WIDTH==9) assign next[WIDTH-1] = curr[2] ^ curr[3] ^ curr[4] ^ curr[5] ^ curr[6] ^ curr[8];


   assign next[WIDTH - 2:0] = curr[WIDTH - 1:1];


   flopenl #(WIDTH) lfsr(clk, reset, lfsrEN, next, val, curr);

   logic [WIDTH-1:0] FirstZero;
   logic [LOGNUMWAYS-1:0] FirstZeroWay;
   logic [LOGNUMWAYS-1:0] VictimWayEnc;

   assign AllValid = &ValidWay;
 
   priorityonehot #(WIDTH) FirstZeroEncoder(~ValidWay, FirstZero);
   binencoder #(WIDTH) FirstZeroWayEncoder(FirstZero, FirstZeroWay);
   mux2 #(LOGNUMWAYS) VictimMux(FirstZeroWay, next[LOGNUMWAYS-1:0], AllValid, VictimWayEnc); // check LFSR size
   decoder #(LOGNUMWAYS) decoder (VictimWayEnc, VictimWay);
endmodule
