///////////////////////////////////////////
// ifu.sv
//
// Written: David_Harris@hmc.edu 9 January 2021
// Modified:
//
// Purpose: Instrunction Fetch Unit
//           PC, branch prediction, instruction cache
// 
// A component of the Wally configurable RISC-V project.
// 
// Copyright (C) 2021 Harvey Mudd College & Oklahoma State University
//
// MIT LICENSE
// Permission is hereby granted, free of charge, to any person obtaining a copy of this 
// software and associated documentation files (the "Software"), to deal in the Software 
// without restriction, including without limitation the rights to use, copy, modify, merge, 
// publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons 
// to whom the Software is furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included in all copies or 
//   substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, 
//   INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR 
//   PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS 
//   BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, 
//   TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE 
//   OR OTHER DEALINGS IN THE SOFTWARE.
////////////////////////////////////////////////////////////////////////////////////////////////

`include "wally-config.vh"

module ifu (
	input logic 				clk, reset,
	input logic 				StallF, StallD, StallE, StallM, StallW,
	input logic 				FlushF, FlushD, FlushE, FlushM, FlushW,
	// Bus interface
(* mark_debug = "true" *)	input logic [`XLEN-1:0] 	IFUBusHRDATA,
(* mark_debug = "true" *)	input logic 				IFUBusAck,
(* mark_debug = "true" *)	output logic [`PA_BITS-1:0] IFUBusAdr,
(* mark_debug = "true" *)	output logic 				IFUBusRead,
(* mark_debug = "true" *)	output logic 				IFUStallF,
	(* mark_debug = "true" *) output logic [`XLEN-1:0] PCF, 
	// Execute
	output logic [`XLEN-1:0] 	PCLinkE,
	input logic 				PCSrcE, 
	input logic [`XLEN-1:0] 	IEUAdrE,
	output logic [`XLEN-1:0] 	PCE,
	output logic 				BPPredWrongE, 
	// Mem
	input logic 				RetM, TrapM, 
	input logic [`XLEN-1:0] 	PrivilegedNextPCM, 
	input logic 				InvalidateICacheM,
	output logic [31:0] 		InstrD, InstrM, 
	output logic [`XLEN-1:0] 	PCM, 
	// branch predictor
	output logic [4:0] 			InstrClassM,
	output logic 				BPPredDirWrongM,
	output logic 				BTBPredPCWrongM,
	output logic 				RASPredPCWrongM,
	output logic 				BPPredClassNonCFIWrongM,
	// Faults
	input logic 				IllegalBaseInstrFaultD,
	output logic 				InstrPageFaultF,
	output logic 				IllegalIEUInstrFaultD,
	output logic 				InstrMisalignedFaultM,
	output logic [`XLEN-1:0] 	InstrMisalignedAdrM,
	input logic 				ExceptionM, PendingInterruptM,
	// mmu management
	input logic [1:0] 			PrivilegeModeW,
	input logic [`XLEN-1:0] 	PTE,
	input logic [1:0] 			PageType,
	input logic [`XLEN-1:0] 	SATP_REGW,
	input logic 				STATUS_MXR, STATUS_SUM, STATUS_MPRV,
	input logic [1:0] 			STATUS_MPP,
	input logic 				ITLBWriteF, ITLBFlushF,
	output logic 				ITLBMissF,
  // pmp/pma (inside mmu) signals.  *** temporarily from AHB bus but eventually replace with internal versions pre H
	input 						var logic [7:0] PMPCFG_ARRAY_REGW[`PMP_ENTRIES-1:0],
	input 						var logic [`XLEN-1:0] PMPADDR_ARRAY_REGW[`PMP_ENTRIES-1:0], 
	output logic 				InstrAccessFaultF,
    output logic                ICacheAccess,
    output logic                ICacheMiss
);

(* mark_debug = "true" *)  logic [`XLEN-1:0]            PCCorrectE, UnalignedPCNextF, PCNextF;
  logic                        BranchMisalignedFaultE;
  logic                        PrivilegedChangePCM;
  logic                        IllegalCompInstrD;
  logic [`XLEN-1:0]            PCPlus2or4F, PCLinkD;
  logic [`XLEN-3:0]            PCPlusUpperF;
  logic                        CompressedF;
  logic [31:0]                 InstrRawD, FinalInstrRawF, InstrRawF;
  logic [31:0]                 InstrE;
  logic [`XLEN-1:0]            PCD;

  localparam [31:0]            nop = 32'h00000013; // instruction for NOP

  logic [`XLEN-1:0] 		   PCBPWrongInvalidate;
  logic 					   BPPredWrongM;

  
(* mark_debug = "true" *)  logic [`PA_BITS-1:0]         PCPF; // used to either truncate or expand PCPF and PCNextF into `PA_BITS width.
  logic [`XLEN+1:0]            PCFExt;

  logic 					   CacheableF;
  logic [`XLEN-1:0]			   PCNextFSpill;
  logic [`XLEN-1:0] 		   PCFSpill;
  logic 					   SelNextSpillF;
  logic 					   ICacheFetchLine;
  logic 					   BusStall;
  logic 					   ICacheStallF, IFUCacheBusStallF;
  logic 					   CPUBusy;
(* mark_debug = "true" *)  logic [31:0] 				   PostSpillInstrRawF;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Spill Support  *** add other banners
  ////////////////////////////////////////////////////////////////////////////////////////////////

  if(`C_SUPPORTED) begin : SpillSupport

    spillsupport spillsupport(.clk, .reset, .StallF, .PCF, .PCPlusUpperF, .PCNextF, .InstrRawF, .IFUCacheBusStallF, .PCNextFSpill, .PCFSpill,
                              .SelNextSpillF, .PostSpillInstrRawF, .CompressedF);
	// end of spill support
  end else begin : NoSpillSupport // line: SpillSupport
    assign PCNextFSpill = PCNextF;
    assign PCFSpill = PCF;
    assign PostSpillInstrRawF = InstrRawF;
    assign {SelNextSpillF, CompressedF} = 0;
  end
  
  assign PCFExt = {2'b00, PCFSpill};

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Memory management
  ////////////////////////////////////////////////////////////////////////////////////////////////

  if(`ZICSR_SUPPORTED == 1) begin : immu
    mmu #(.TLB_ENTRIES(`ITLB_ENTRIES), .IMMU(1))
    immu(.clk, .reset, .SATP_REGW, .STATUS_MXR, .STATUS_SUM, .STATUS_MPRV, .STATUS_MPP,
         .PrivilegeModeW, .DisableTranslation(1'b0),
         .PAdr(PCFExt[`PA_BITS-1:0]),
         .VAdr(PCFSpill),
         .Size(2'b10),
         .PTE(PTE),
         .PageTypeWriteVal(PageType),
         .TLBWrite(ITLBWriteF),
         .TLBFlush(ITLBFlushF),
         .PhysicalAddress(PCPF),
         .TLBMiss(ITLBMissF),
         .Cacheable(CacheableF), .Idempotent(), .AtomicAllowed(),
         .InstrAccessFaultF, .LoadAccessFaultM(), .StoreAmoAccessFaultM(),
         .InstrPageFaultF, .LoadPageFaultM(), .StoreAmoPageFaultM(),
         .LoadMisalignedFaultM(), .StoreAmoMisalignedFaultM(),
         .AtomicAccessM(1'b0),.ExecuteAccessF(1'b1), .WriteAccessM(1'b0), .ReadAccessM(1'b0),
         .PMPCFG_ARRAY_REGW, .PMPADDR_ARRAY_REGW);

  end else begin
    assign {ITLBMissF, InstrAccessFaultF} = '0;
    assign InstrPageFaultF = '0;
    assign PCPF = PCF;
    assign CacheableF = '1;
  end
  // conditional
  // 1. ram // controlled by `MEM_IROM
  // 2. cache // `MEM_ICACHE
  // 3. wire pass-through

  // If we have `MEM_IROM we don't have the bus controller
  // otherwise we have the bus controller and either a cache or a passthrough.


  // *** make this area look like LSU, including moving I$.  Hide localparams in submodules when feasible

  localparam integer   WORDSPERLINE = `MEM_ICACHE ? `ICACHE_LINELENINBITS/`XLEN : 1;
  localparam integer   LOGWPL = `MEM_ICACHE ? $clog2(WORDSPERLINE) : 1;
  localparam integer   LINELEN = `MEM_ICACHE ? `ICACHE_LINELENINBITS : `XLEN;
  localparam integer   WordCountThreshold = `MEM_ICACHE ? WORDSPERLINE - 1 : 0;

  localparam integer   LINEBYTELEN = LINELEN/8;
  localparam integer   OFFSETLEN = $clog2(LINEBYTELEN);

  logic [LOGWPL-1:0]   WordCount;
  logic [LINELEN-1:0]  ICacheMemWriteData;
  logic 			   ICacheBusAck;
  logic [`PA_BITS-1:0] LocalIFUBusAdr;
  logic [`PA_BITS-1:0] ICacheBusAdr;
  logic 			   SelUncachedAdr;
  
  if (`MEM_IROM) begin : irom
	logic [`XLEN-1:0] FinalInstrRawF_FIXME;

    simpleram #(
        .BASE(`RAM_BASE), .RANGE(`RAM_RANGE)) ram (
        .clk, 
        .a(CPUBusy | reset ? PCPF[31:0] : PCNextFSpill[31:0]), // mux is also inside $, have to replay address if CPU is stalled.
        .we(1'b0),
        .wd(0), .rd(FinalInstrRawF_FIXME));
	assign FinalInstrRawF = FinalInstrRawF_FIXME[31:0];
    assign BusStall = 0;
    assign IFUBusRead = 0;
    assign ICacheBusAck = 0;
    assign SelUncachedAdr = 0;
    assign IFUBusAdr = 0;
    assign ICacheStallF = '0;
  end else begin : bus
      genvar 			   index;
      for (index = 0; index < WORDSPERLINE; index++) begin:fetchbuffer
        flopen #(`XLEN) fb(.clk(clk),
                           .en(IFUBusAck & IFUBusRead & (index == WordCount)),
                           .d(IFUBusHRDATA),
                           .q(ICacheMemWriteData[(index+1)*`XLEN-1:index*`XLEN]));
      end

      assign LocalIFUBusAdr = SelUncachedAdr ? PCPF : ICacheBusAdr;
      assign IFUBusAdr = ({{`PA_BITS-LOGWPL{1'b0}}, WordCount} << $clog2(`XLEN/8)) + LocalIFUBusAdr;

      busfsm #(WordCountThreshold, LOGWPL, `MEM_ICACHE)
      busfsm(.clk, .reset, .IgnoreRequest(ITLBMissF),
		     .LSURWM(2'b10), .DCacheFetchLine(ICacheFetchLine), .DCacheWriteLine(1'b0), 
		     .LSUBusAck(IFUBusAck),
		     .CPUBusy, .CacheableM(CacheableF),
		     .BusStall, .LSUBusWrite(), .LSUBusRead(IFUBusRead), .DCacheBusAck(ICacheBusAck),
		     .BusCommittedM(), .SelUncachedAdr(SelUncachedAdr), .WordCount);

    if(`MEM_ICACHE) begin : icache
      logic [1:0] IFURWF;
      assign IFURWF = CacheableF ? 2'b10 : 2'b00;
      
      logic [`XLEN-1:0] FinalInstrRawF_FIXME;
      
      cache #(.LINELEN(`ICACHE_LINELENINBITS),
              .NUMLINES(`ICACHE_WAYSIZEINBYTES*8/`ICACHE_LINELENINBITS),
              .NUMWAYS(`ICACHE_NUMWAYS), .DCACHE(0))
      icache(.clk, .reset, .CPUBusy, .IgnoreRequest(ITLBMissF), .CacheMemWriteData(ICacheMemWriteData) , .CacheBusAck(ICacheBusAck),
             .CacheBusAdr(ICacheBusAdr), .CacheStall(ICacheStallF), .ReadDataWord(FinalInstrRawF_FIXME),
             .CacheFetchLine(ICacheFetchLine),
             .CacheWriteLine(),
             .ReadDataLineSets(),
             .CacheMiss(ICacheMiss),
             .CacheAccess(ICacheAccess),
             .FinalWriteData('0),
             .RW(IFURWF), 
             .Atomic(2'b00),
             .FlushCache(1'b0),
             .NextAdr(PCNextFSpill[11:0]),
             .PAdr(PCPF),
             .CacheCommitted(),
             .InvalidateCacheM(InvalidateICacheM));

      assign FinalInstrRawF = FinalInstrRawF_FIXME[31:0];
    end else begin : passthrough
      assign ICacheFetchLine = '0;
      assign ICacheBusAdr = '0;
      assign ICacheStallF = '0;
	  assign FinalInstrRawF = '0;
      assign ICacheAccess = CacheableF;
      assign ICacheMiss = CacheableF;
    end
    

  end
  
  
  // branch predictor signal
  logic                        SelBPPredF;
  logic [`XLEN-1:0]            BPPredPCF, PCNext0F, PCNext1F, PCNext2F;
  logic [4:0]                  InstrClassD, InstrClassE;


  // select between dcache and direct from the BUS. Always selected if no dcache.
  // handled in the busfsm.
  mux2 #(32) UnCachedInstrMux(.d0(FinalInstrRawF), .d1(ICacheMemWriteData[31:0]), .s(SelUncachedAdr), .y(InstrRawF));

  assign IFUCacheBusStallF = ICacheStallF | BusStall;
  assign IFUStallF = IFUCacheBusStallF | SelNextSpillF;
  assign CPUBusy = StallF & ~SelNextSpillF;
  
  flopenl #(32) AlignedInstrRawDFlop(clk, reset, ~StallD, FlushD ? nop : PostSpillInstrRawF, nop, InstrRawD);

  assign PrivilegedChangePCM = RetM | TrapM;

  // *** move unnecessary muxes into BPRED_ENABLED
  mux2 #(`XLEN) pcmux0(.d0(PCPlus2or4F), .d1(BPPredPCF), .s(SelBPPredF), .y(PCNext0F));
  mux2 #(`XLEN) pcmux1(.d0(PCNext0F), .d1(PCCorrectE), .s(BPPredWrongE), .y(PCNext1F));
  // The true correct target is IEUAdrE if PCSrcE is 1 else it is the fall through PCLinkE.
  mux2 #(`XLEN) pccorrectemux(.d0(PCLinkE), .d1(IEUAdrE), .s(PCSrcE), .y(PCCorrectE));
  mux2 #(`XLEN) pcmux2(.d0(PCNext1F), .d1(PCBPWrongInvalidate), .s(InvalidateICacheM), .y(PCNext2F));
  // Mux only required on instruction class miss prediction.
  mux2 #(`XLEN) pcmuxBPWrongInvalidateFlush(.d0(PCE), .d1(PCF), .s(BPPredWrongM), .y(PCBPWrongInvalidate));
  mux2 #(`XLEN) pcmux3(.d0(PCNext2F), .d1(PrivilegedNextPCM), .s(PrivilegedChangePCM), .y(UnalignedPCNextF));

  assign  PCNextF = {UnalignedPCNextF[`XLEN-1:1], 1'b0}; // hart-SPEC p. 21 about 16-bit alignment
  flopenl #(`XLEN) pcreg(clk, reset, ~StallF, PCNextF, `RESET_VECTOR, PCF);

  // branch and jump predictor
  if (`BPRED_ENABLED) begin : bpred
    // *** move the rest of this hardware into branch predictor including instruction class registers
    logic BPPredDirWrongE, BTBPredPCWrongE, RASPredPCWrongE, BPPredClassNonCFIWrongE;

  flopenrc #(1) BPPredWrongMReg(.clk, .reset, .en(~StallM), .clear(FlushM), .d(BPPredWrongE), .q(BPPredWrongM));

    bpred bpred(.clk, .reset,
        .StallF, .StallD, .StallE,
        .FlushF, .FlushD, .FlushE,
        .PCNextF, .BPPredPCF, .SelBPPredF, .PCE, .PCSrcE, .IEUAdrE,
        .PCD, .PCLinkE, .InstrClassE, .BPPredWrongE, .BPPredDirWrongE,
        .BTBPredPCWrongE, .RASPredPCWrongE, .BPPredClassNonCFIWrongE);

    // the branch predictor needs a compact decoding of the instruction class.
    // *** consider adding in the alternate return address x5 for returns.
    assign InstrClassD[4] = (InstrD[6:0] & 7'h77) == 7'h67 & (InstrD[11:07] & 5'h1B) == 5'h01; // jal(r) must link to ra or r5
    assign InstrClassD[3] = InstrD[6:0] == 7'h67 & (InstrD[19:15] & 5'h1B) == 5'h01; // return must return to ra or r5
    assign InstrClassD[2] = InstrD[6:0] == 7'h67 & (InstrD[19:15] & 5'h1B) != 5'h01 & (InstrD[11:7] & 5'h1B) != 5'h01; // jump register, but not return
    assign InstrClassD[1] = InstrD[6:0] == 7'h6F & (InstrD[11:7] & 5'h1B) != 5'h01; // jump, RD != x1 or x5
    assign InstrClassD[0] = InstrD[6:0] == 7'h63; // branch

    // branch predictor
    flopenrc #(5) InstrClassRegE(.clk, .reset, .en(~StallE), .clear(FlushE), .d(InstrClassD), .q(InstrClassE));
    flopenrc #(5) InstrClassRegM(.clk, .reset, .en(~StallM), .clear(FlushM), .d(InstrClassE), .q(InstrClassM));
    flopenrc #(4) BPPredWrongRegM(.clk, .reset, .en(~StallM), .clear(FlushM),
                 .d({BPPredDirWrongE, BTBPredPCWrongE, RASPredPCWrongE, BPPredClassNonCFIWrongE}),
                 .q({BPPredDirWrongM, BTBPredPCWrongM, RASPredPCWrongM, BPPredClassNonCFIWrongM}));
  
  end else begin : bpred
    assign BPPredPCF = '0;
    assign BPPredWrongE = PCSrcE;
    assign BPPredWrongM = '0;
    assign {SelBPPredF, BPPredDirWrongM, BTBPredPCWrongM, RASPredPCWrongM, BPPredClassNonCFIWrongM} = '0;
  end      

  // pcadder
  // add 2 or 4 to the PC, based on whether the instruction is 16 bits or 32
  assign PCPlusUpperF = PCF[`XLEN-1:2] + 1; // add 4 to PC
  // choose PC+2 or PC+4 based on CompressedF, which arrives later. 
  // Speeds up critical path as compared to selecting adder input based on CompressedF
  always_comb
    if (CompressedF) // add 2
      if (PCF[1]) PCPlus2or4F = {PCPlusUpperF, 2'b00}; 
      else        PCPlus2or4F = {PCF[`XLEN-1:2], 2'b10};
    else          PCPlus2or4F = {PCPlusUpperF, PCF[1:0]}; // add 4

  
  // Decode stage pipeline register and logic
  flopenrc #(`XLEN) PCDReg(clk, reset, FlushD, ~StallD, PCF, PCD);
   
  // expand 16-bit compressed instructions to 32 bits

  decompress decomp(.InstrRawD, .InstrD, .IllegalCompInstrD);
  assign IllegalIEUInstrFaultD = IllegalBaseInstrFaultD | IllegalCompInstrD; // illegal if bad 32 or 16-bit instr
  // *** combine these with others in better way, including M, F


  // Misaligned PC logic
  // Instruction address misalignement only from br/jal(r) instructions.
  // instruction address misalignment is generated by the target of control flow instructions, not
  // the fetch itself.
  // xret and Traps both cannot produce instruction misaligned.
  // xret: mepc is an MXLEN-bit read/write register formatted as shown in Figure 3.21. 
  // The low bit of mepc (mepc[0]) is always zero. On implementations that support
  // only IALIGN=32, the two low bits (mepc[1:0]) are always zero.
  // Spec 3.1.14
  // Traps: Can’t happen.  The bottom two bits of MTVEC are ignored so the trap always is to a multiple of 4.  See 3.1.7 of the privileged spec.
  assign BranchMisalignedFaultE = (IEUAdrE[1] & ~`C_SUPPORTED) & PCSrcE;
  flopenr #(1) InstrMisalginedReg(clk, reset, ~StallM, BranchMisalignedFaultE, InstrMisalignedFaultM);
  // *** Ross Thompson. Check InstrMisalignedAdrM as I believe it is the same as PCF.  Should be able to remove.
  flopenr #(`XLEN) InstrMisalignedAdrReg(clk, reset, ~StallM, PCNextF, InstrMisalignedAdrM);

  // Instruction and PC/PCLink pipeline registers
  flopenr  #(32)   InstrEReg(clk, reset, ~StallE, FlushE ? nop : InstrD, InstrE);
  flopenr  #(32)   InstrMReg(clk, reset, ~StallM, FlushM ? nop : InstrE, InstrM);
  flopenr #(`XLEN) PCEReg(clk, reset, ~StallE, PCD, PCE);
  flopenr #(`XLEN) PCMReg(clk, reset, ~StallM, PCE, PCM);
  flopenr #(`XLEN) PCPDReg(clk, reset, ~StallD, PCPlus2or4F, PCLinkD);
  flopenr #(`XLEN) PCPEReg(clk, reset, ~StallE, PCLinkD, PCLinkE);
endmodule
