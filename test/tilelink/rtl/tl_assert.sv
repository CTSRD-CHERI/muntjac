// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "tl_assert_util.svh"

// Module which checks that all communication through a TileLink port adheres
// to the required protocol.
module tl_assert import tl_pkg::*; #(
    parameter  tl_protocol_e Protocol     = TL_C,
    parameter                EndpointType = "Device", // Or "Host"
    parameter  int unsigned  AddrWidth    = 56,
    parameter  int unsigned  DataWidth    = 64,
    parameter  int unsigned  SinkWidth    = 1,
    parameter  int unsigned  SourceWidth  = 1
) (
  input  logic            clk_i,
  input  logic            rst_ni,
  `TL_DECLARE_TAP_PORT(DataWidth, AddrWidth, SourceWidth, SinkWidth, tl)
);

  localparam int unsigned DataWidthInBytes = DataWidth / 8;

  // 4096 = maximum message size (in bytes) specified by TileLink.
  localparam int unsigned MaxBeats = 4096 / DataWidthInBytes;

  // The number of beats expected in a burst message with a given size.
  function logic [$bits(MaxBeats)-1:0] expected_beats(
    input logic [`TL_SIZE_WIDTH-1:0] size
  );
    expected_beats = ((1 << size) < DataWidthInBytes) ? 1 : (1 << size) / DataWidthInBytes;
  endfunction

  // Copy input TileLink fields to local variables.
  `TL_DECLARE(DataWidth, AddrWidth, SourceWidth, SinkWidth, tl);
  // `TL_BIND_TAP_PORT(tl, tl);

  // Latch the previous input so we can look at transitions.
  `TL_DECLARE(DataWidth, AddrWidth, SourceWidth, SinkWidth, prev_tl);
  `TL_DECLARE(DataWidth, AddrWidth, SourceWidth, SinkWidth, prev_accepted);
  `TL_DECLARE(DataWidth, AddrWidth, SourceWidth, SinkWidth, prev_declined);

  // Capture the last accepted/declined beats from a named channel.
  // TODO: this is for functional coverage. Not tested yet.
  // TODO: focus on non-continuous matches.
  // TODO: accepted being valid doesn't make declined invalid.
  `define COVERAGE_CAPTURE(CHANNEL)                                      \
    if (tl_``CHANNEL``_valid) begin                             \
      prev_accepted_``CHANNEL``_valid <= tl_``CHANNEL``_ready;  \
      prev_declined_``CHANNEL``_valid <= !tl_``CHANNEL``_ready; \
                                                                \
      if (tl_``CHANNEL``_ready) begin                           \
        prev_accepted_``CHANNEL`` <= tl_``CHANNEL``;            \
      end else begin                                            \
        prev_declined_``CHANNEL`` <= tl_``CHANNEL``;            \
      end                                                       \
    end

  always_ff @(posedge clk_i) begin
    `COVERAGE_CAPTURE(a);
    `COVERAGE_CAPTURE(b);
    `COVERAGE_CAPTURE(c);
    `COVERAGE_CAPTURE(d);
    `COVERAGE_CAPTURE(e);
  end

  `undef COVERAGE_CAPTURE

  ////////////////////////////////////
  // Keep track of pending requests //
  ////////////////////////////////////

  // Keep track of requests/responses whose transactions are not yet complete.
  //  - pend   : set to 1 to indicate a pending request
  //  - beats  : number of request beats seen so far in this burst
  //  - resps  : number of response beats seen
  //  - tl     : all TileLink fields
  typedef struct packed {
    bit                          pend;
    logic [$bits(MaxBeats)-1:0]  beats;
    logic [$bits(MaxBeats)-1:0]  resps;
    `TL_A_STRUCT(DataWidth, AddrWidth, SourceWidth, SinkWidth) tl;
  } a_req_t;

  typedef struct packed {
    bit                          pend;
    logic [$bits(MaxBeats)-1:0]  beats;
    `TL_B_STRUCT(DataWidth, AddrWidth, SourceWidth, SinkWidth) tl;
  } b_req_t;

  typedef struct packed {
    bit                          pend;
    logic [$bits(MaxBeats)-1:0]  beats;
    `TL_C_STRUCT(DataWidth, AddrWidth, SourceWidth, SinkWidth) tl;
  } c_req_t;

  typedef struct packed {
    bit                          pend;
    logic [$bits(MaxBeats)-1:0]  beats;
    `TL_D_STRUCT(DataWidth, AddrWidth, SourceWidth, SinkWidth) tl;
  } d_req_t;

  // The A and C channels may have at most one pending transaction per SourceID.
  // The D channel may have at most one pending transaction per SinkID.
  // There is no need to track E transactions because nothing depends on them.
  // The B channel can have an outstanding request for any {source, address}.
  // This is too many to keep track of using the same simple method.
  a_req_t [2**SourceWidth-1:0] a_pending;
  // b_req_t [2**SourceWidth-1:0] b_pending;
  c_req_t [2**SourceWidth-1:0] c_pending;
  d_req_t [2**SinkWidth-1:0]   d_pending;

  // Order of operations:
  //  1. Clear complete requests
  //  2. Capture new inputs
  //  3. Update outstanding requests
  // This order is used so the assertions can see the final state of a message
  // before it is cleared.
  // This assumes that none of the TileLink signals are updated on the negative
  // clock edge.
  always_ff @(negedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      a_pending = '0;
      // b_pending = '0;
      c_pending = '0;
      d_pending = '0;
    end else begin
      // 1. Clear complete requests.

      // C message length depends on operation. Exclude Release and ReleaseData
      // which must remain active until a response is seen on the D channel.
      if (tl_c_valid && tl_c_ready) begin
        if (tl_c.opcode inside {AccessAck, HintAck, ProbeAck} ||
            (tl_c.opcode inside {AccessAckData, ProbeAckData} &&
             c_pending[tl_c.source].beats == expected_beats(c_pending[tl_c.source].tl.size))) begin
          c_pending[tl_c.source].pend     = 0;
        end
      end

      // D messages can be responses to either the C channel (always 1 beat),
      // or the A channel (length depends on operation).
      if (tl_d_valid && tl_d_ready) begin
        if (tl_d.opcode inside {ReleaseAck}) begin
          c_pending[tl_d.source].pend     = 0;
        end else begin
          if (tl_d.opcode inside {AccessAck, HintAck, Grant, ReleaseAck} ||
              a_pending[tl_d.source].resps == expected_beats(a_pending[tl_d.source].tl.size)) begin
            a_pending[tl_d.source].pend   = 0;
          end
        end
      end

      // E messages always contain one beat, so clear D requests immediately.
      if (tl_e_valid && tl_e_ready) begin
        d_pending[tl_e.sink].pend         = 0;
      end

      // 2. Capture new inputs.
      `TL_ASSIGN_B(prev_tl, tl);
      `TL_ASSIGN_B_FROM_TAP(tl, tl);

      // 3. Update outstanding requests.

      if (tl_a_valid && tl_a_ready) begin
        // Capture request information on first beat.
        if (!a_pending[tl_a.source].pend) begin
          a_pending[tl_a.source].pend     = 1;
          a_pending[tl_a.source].tl       = tl_a;
          a_pending[tl_a.source].beats    = 0;
          a_pending[tl_a.source].resps    = 0;
        end
        
        a_pending[tl_a.source].beats      = a_pending[tl_a.source].beats + 1;
      end

      // Can't do B channel with current approach because there can be
      // too many outstanding requests to track.

      if (tl_c_valid && tl_c_ready) begin
        // Capture request information on first beat.
        if (!c_pending[tl_c.source].pend) begin
          c_pending[tl_c.source].pend     = 1;
          c_pending[tl_c.source].tl       = tl_c;
          c_pending[tl_c.source].beats    = 0;
        end
        
        c_pending[tl_c.source].beats      = c_pending[tl_c.source].beats + 1;
      end

      if (tl_d_valid && tl_d_ready) begin
        // Capture request information on first beat, only for operations that
        // will receive a response.
        // I think we still expect an ack even if the request was denied.
        if (!d_pending[tl_d.sink].pend && tl_d.opcode inside {Grant, GrantData}) begin
          d_pending[tl_d.sink].pend       = 1;
          d_pending[tl_d.sink].tl         = tl_d;
          d_pending[tl_d.sink].beats      = 0;
        end
        
        d_pending[tl_d.sink].beats        = d_pending[tl_d.sink].beats + 1;

        // Update response count if responding to A channel.
        if (tl_d.opcode != ReleaseAck) begin
          a_pending[tl_d.source].resps    = a_pending[tl_d.source].resps + 1;
        end
      end

      // Nothing to track for E channel.
    end
  end

  /////////////////////////////////////////
  // A channel                           //
  /////////////////////////////////////////

  `SEQUENCE(aAccepted_S, tl_a_valid && tl_a_ready);

  // a.opcode
  `SEQUENCE(aLegalOpcodeTLUL_S,
    tl_a.opcode inside {PutFullData, PutPartialData, Get}
  );
  `SEQUENCE(aLegalOpcodeTLUH_S,
    aLegalOpcodeTLUL_S `OR
    tl_a.opcode inside {ArithmeticData, LogicalData, Intent}
  );
  `SEQUENCE(aLegalOpcodeTLC_S,
    aLegalOpcodeTLUH_S `OR tl_a.opcode inside {AcquireBlock, AcquirePerm}
  );

  `SEQUENCE(aLegalOpcode_S,
    (Protocol == TL_UL) ? aLegalOpcodeTLUL_S :
    (Protocol == TL_UH) ? aLegalOpcodeTLUH_S :
                          aLegalOpcodeTLC_S
  );

  `SEQUENCE(aHasPayload_S, 
    tl_a.opcode inside {PutFullData, PutPartialData, ArithmeticData, LogicalData}
  );

  // a.param
  `SEQUENCE(aLegalParam_S, 
    (tl_a.opcode inside {PutFullData, PutPartialData, Get} && tl_a.param === '0) ||
    (tl_a.opcode == ArithmeticData && tl_a.param inside {[0:4]}) ||
    (tl_a.opcode == LogicalData    && tl_a.param inside {[0:3]}) ||
    (tl_a.opcode == Intent         && tl_a.param inside {[0:1]}) ||
    (tl_a.opcode inside {AcquireBlock, AcquirePerm} && tl_a.param inside {[0:2]})
  );

  // a.size: Size shouldn't be greater than the bus width in TL-UL.
  `SEQUENCE(aSizeLTEBusWidth_S, 
    (Protocol != TL_UL) || ((1 << tl_a.size) <= DataWidthInBytes)
  );

  // a.size: 2**a.size must be greater than or equal to $countones(a.mask).
  // TODO: not sure about this. Originally excluded PutFullData, but I don't
  //       understand why.
  `SEQUENCE(aSizeGTEMask_S,
    (1 << tl_a.size) >= $countones(tl_a.mask)
  );

  // a.size: 2**a.size must equal $countones(a.mask) for PutFull. This only
  //         applies to TL-UL: the heavier protocols allow multi-beat messages.
  `SEQUENCE(aSizeMatchesMask_S,
    (Protocol != TL_UL) ||
    (tl_a.opcode inside {PutPartialData, Get}) ||
    ((1 << tl_a.size) === $countones(tl_a.mask))
  );

  // a.size: we expect a certain number of beats in burst messages.
  `SEQUENCE(aNumBeats_S,
    `IMPLIES(aHasPayload_S, 
      a_pending[tl_a.source].beats <= expected_beats(tl_a.size)
    )
  );

  // a.address: must be aligned to a.size (for the first beat only).
  `SEQUENCE(aFirstBeat_S, a_pending[tl_a.source].beats == 1);
  `SEQUENCE(aAddrSizeAligned_S, 
    `IMPLIES(aFirstBeat_S, (tl_a.address & ((1 << tl_a.size) - 1)) == '0)
  );

  // a.address: must increment by DataWidthInBytes within multibeat messages.
  `SEQUENCE(aFollowingBeat_S, a_pending[tl_a.source].beats > 1);
  `SEQUENCE(aAddressMultibeatInc_S,
    `IMPLIES(aFollowingBeat_S,
      tl_a.address == a_pending[tl_a.source].tl.address + 
                      (a_pending[tl_a.source].beats - 1) * DataWidthInBytes
    )
  );

  // Most control signals must remain constant within multibeat messages.
  `SEQUENCE(aMultibeatCtrlConst_S,
    `IMPLIES(aFollowingBeat_S,
      (tl_a.opcode == a_pending[tl_a.source].tl.opcode) &&
      (tl_a.param == a_pending[tl_a.source].tl.param) &&
      (tl_a.size == a_pending[tl_a.source].tl.size) &&
      (tl_a.source == a_pending[tl_a.source].tl.source)
    )
  );

  // a.mask: must be contiguous for some operations.
  `SEQUENCE(aContigMask_pre_S, 
    tl_a.opcode inside {Get, PutFullData, AcquireBlock, AcquirePerm} // Intent?
  );

  `SEQUENCE(aContigMask_S,
    `IMPLIES(aContigMask_pre_S,
      $countones(tl_a.mask ^ {tl_a.mask[$bits(tl_a.mask)-2:0], 1'b0}) <= 2
    )
  );

  // a.mask: must be aligned to the bus width when size is less than bus width.
  //         i.e. if 2 bytes are sent on a 4 byte channel, either the upper 2 or
  //         lower 2 mask bits may be set, depending on address alignment.
  //         Here we ensure that every other mask bit is unset.
  `SEQUENCE(aFullBusUsed_S, (1 << tl_a.size) >= DataWidthInBytes);

  `SEQUENCE(aFullMaskUsed_S, 
    `IMPLIES(aFullBusUsed_S, tl_a.mask == {DataWidthInBytes{1'b1}})
  );

  // DataWidth / 8 = num bytes in data bus = num bits in mask
  // address & (mask bits - 1) = data offset within bus
  // 1 << size = data length
  // (data length - 1) << offset = largest possible mask given size and address
  logic [DataWidthInBytes-1:0] aMaxMask;
  assign aMaxMask = ((1 << tl_a.size) - 1) << (tl_a.address & (DataWidthInBytes - 1));
  `SEQUENCE(aMaskAligned_S, 
    `IMPLIES(`NOT aFullBusUsed_S, (tl_a.mask & ~aMaxMask) == '0)
  );

  // a.data: must be known for operations with payloads.
  `SEQUENCE(aDataKnown_S,
    `IMPLIES(aHasPayload_S,
      // no check if this lane mask is inactive
      ((!tl_a.mask[0]) || (tl_a.mask[0] && !$isunknown(tl_a.data[8*0 +: 8]))) &&
      ((!tl_a.mask[1]) || (tl_a.mask[1] && !$isunknown(tl_a.data[8*1 +: 8]))) &&
      ((!tl_a.mask[2]) || (tl_a.mask[2] && !$isunknown(tl_a.data[8*2 +: 8]))) &&
      ((!tl_a.mask[3]) || (tl_a.mask[3] && !$isunknown(tl_a.data[8*3 +: 8]))) &&
      ((!tl_a.mask[4]) || (tl_a.mask[4] && !$isunknown(tl_a.data[8*4 +: 8]))) &&
      ((!tl_a.mask[5]) || (tl_a.mask[5] && !$isunknown(tl_a.data[8*5 +: 8]))) &&
      ((!tl_a.mask[6]) || (tl_a.mask[6] && !$isunknown(tl_a.data[8*6 +: 8]))) &&
      ((!tl_a.mask[7]) || (tl_a.mask[7] && !$isunknown(tl_a.data[8*7 +: 8])))
    )
  );

  // a.corrupt: only operations with payloads may set a.corrupt to 1.
  `SEQUENCE(aLegalCorrupt_S, `IMPLIES(`NOT aHasPayload_S, !tl_a.corrupt));

  /////////////////////////////////////////
  // B channel                           //
  /////////////////////////////////////////

  `SEQUENCE(bAccepted_S, tl_b_valid && tl_b_ready);
  `SEQUENCE(bEnabled_S, Protocol == TL_C);

  // b.opcode
  `SEQUENCE(bLegalOpcode_S,
    tl_b.opcode inside {PutFullData, PutPartialData, Get,
                        ArithmeticData, LogicalData, Intent,
                        ProbeBlock, ProbePerm}
  );

  `SEQUENCE(bHasPayload_S, 
    tl_b.opcode inside {PutFullData, PutPartialData, ArithmeticData, LogicalData}
  );

  // b.param
  // Almost identical to A channel since messages can be forwarded, but
  // AcquireBlock and AcquirePerm are replaced with ProbeBlock and ProbePerm.
  `SEQUENCE(bLegalParam_S, 
    (tl_b.opcode inside {PutFullData, PutPartialData, Get} && tl_b.param === '0) ||
    (tl_b.opcode == ArithmeticData && tl_b.param inside {[0:4]}) ||
    (tl_b.opcode == LogicalData    && tl_b.param inside {[0:3]}) ||
    (tl_b.opcode == Intent         && tl_b.param inside {[0:1]}) ||
    (tl_b.opcode inside {ProbeBlock, ProbePerm} && tl_b.param inside {[0:2]})
  );

  // TODO: lots of copy/paste from A channel from here on. Can this be tidied?

  // b.size: 2**b.size must be greater than or equal to $countones(b.mask).
  // TODO: not sure about this. Originally excluded PutFullData, but I don't
  //       understand why.
  `SEQUENCE(bSizeGTEMask_S,
    (1 << tl_b.size) >= $countones(tl_b.mask)
  );
  
  // DON'T USE THIS. TileLink B messages cannot be uniquely identified using
  // only a source ID: they need an address too. This allows too many pending
  // requests to reasonably track.

  // b.size: we expect a certain number of beats in burst messages.
  // `SEQUENCE(bNumBeats_S,
  //   `IMPLIES(bHasPayload_S, 
  //     b_pending[tl_b.source].beats <= expected_beats(tl_b.size)
  //   )
  // );

  // b.address: must be aligned to b.size (for the first beat only).
  // `SEQUENCE(bFirstBeat_S, b_pending[tl_b.source].beats == 1);
  // `SEQUENCE(bAddrSizeAligned_S, 
  //   `IMPLIES(bFirstBeat_S, (tl_b.address & ((1 << tl_b.size) - 1)) == '0)
  // );

  // b.address: must increment by DataWidthInBytes within multibeat messages.
  // `SEQUENCE(bFollowingBeat_S, b_pending[tl_b.source].beats > 1);
  // `SEQUENCE(bAddressMultibeatInc_S,
  //   `IMPLIES(bFollowingBeat_S,
  //     tl_b.address == b_pending[tl_b.source].tl.address + 
  //                     (b_pending[tl_b.source].beats - 1) * DataWidthInBytes
  //   )
  // );

  // Most control signals must remain constant within multibeat messages.
  // `SEQUENCE(bMultibeatCtrlConst_S,
  //   `IMPLIES(bFollowingBeat_S,
  //     (tl_b.opcode == b_pending[tl_b.source].tl.opcode) &&
  //     (tl_b.param == b_pending[tl_b.source].tl.param) &&
  //     (tl_b.size == b_pending[tl_b.source].tl.size) &&
  //     (tl_b.source == b_pending[tl_b.source].tl.source)
  //   )
  // );

  // b.mask: must be contiguous for some operations.
  `SEQUENCE(bContigMask_pre_S, 
    tl_b.opcode inside {Get, PutFullData, AcquireBlock, AcquirePerm} // Intent?
  );

  `SEQUENCE(bContigMask_S,
    `IMPLIES(bContigMask_pre_S,
      $countones(tl_b.mask ^ {tl_b.mask[$bits(tl_b.mask)-2:0], 1'b0}) <= 2
    )
  );

  // b.mask: must be aligned to the bus width when size is less than bus width.
  //         i.e. if 2 bytes are sent on a 4 byte channel, either the upper 2 or
  //         lower 2 mask bits may be set, depending on address alignment.
  //         Here we ensure that every other mask bit is unset.
  `SEQUENCE(bFullBusUsed_S, (1 << tl_b.size) >= DataWidthInBytes);

  `SEQUENCE(bFullMaskUsed_S, 
    `IMPLIES(bFullBusUsed_S, tl_b.mask == {DataWidthInBytes{1'b1}})
  );

  // DataWidth / 8 = num bytes in data bus = num bits in mask
  // address & (mask bits - 1) = data offset within bus
  // 1 << size = data length
  // (data length - 1) << offset = largest possible mask given size and address
  logic [DataWidthInBytes-1:0] bMaxMask;
  assign bMaxMask = ((1 << tl_b.size) - 1) << (tl_b.address & (DataWidthInBytes - 1));
  `SEQUENCE(bMaskAligned_S, 
    `IMPLIES(`NOT bFullBusUsed_S, (tl_b.mask & ~bMaxMask) == '0)
  );

  // b.data: must be known for operations with payloads.
  `SEQUENCE(bDataKnown_S,
    `IMPLIES(bHasPayload_S,
      // no check if this lane mask is inactive
      ((!tl_b.mask[0]) || (tl_b.mask[0] && !$isunknown(tl_b.data[8*0 +: 8]))) &&
      ((!tl_b.mask[1]) || (tl_b.mask[1] && !$isunknown(tl_b.data[8*1 +: 8]))) &&
      ((!tl_b.mask[2]) || (tl_b.mask[2] && !$isunknown(tl_b.data[8*2 +: 8]))) &&
      ((!tl_b.mask[3]) || (tl_b.mask[3] && !$isunknown(tl_b.data[8*3 +: 8]))) &&
      ((!tl_b.mask[4]) || (tl_b.mask[4] && !$isunknown(tl_b.data[8*4 +: 8]))) &&
      ((!tl_b.mask[5]) || (tl_b.mask[5] && !$isunknown(tl_b.data[8*5 +: 8]))) &&
      ((!tl_b.mask[6]) || (tl_b.mask[6] && !$isunknown(tl_b.data[8*6 +: 8]))) &&
      ((!tl_b.mask[7]) || (tl_b.mask[7] && !$isunknown(tl_b.data[8*7 +: 8])))
    )
  );

  // b.corrupt: only operations with payloads may set b.corrupt to 1.
  `SEQUENCE(bLegalCorrupt_S, `IMPLIES(`NOT bHasPayload_S, !tl_b.corrupt));

  /////////////////////////////////////////
  // C channel                           //
  /////////////////////////////////////////

  `SEQUENCE(cAccepted_S, tl_c_valid && tl_c_ready);
  `SEQUENCE(cEnabled_S, Protocol == TL_C);

  // c.opcode
  `SEQUENCE(cLegalOpcode_S,
    tl_c.opcode inside {AccessAckData, AccessAck, HintAck,
                        ProbeAck, ProbeAckData, Release, ReleaseData}
  );

  `SEQUENCE(cHasPayload_S, 
    tl_c.opcode inside {AccessAckData, ProbeAckData, ReleaseData}
  );

  // DON'T USE THIS. TileLink B messages cannot be uniquely identified using
  // only a source ID: they need an address too. This allows too many pending
  // requests to reasonably track.

  // Ensure opcode matches pending request.
  // `SEQUENCE(cMatchingOpcode_S,
  //   (tl_c.opcode == AccessAckData && b_pending[tl_c.source].tl.opcode inside {Get, ArithmeticData, LogicalData}) ||
  //   (tl_c.opcode == AccessAck     && b_pending[tl_c.source].tl.opcode inside {PutFullData, PutPartialData}) ||
  //   (tl_c.opcode == HintAck       && b_pending[tl_c.source].tl.opcode inside {Intent}) ||
  //   (tl_c.opcode == ProbeAck      && b_pending[tl_c.source].tl.opcode inside {ProbeBlock, ProbePerm}) ||
  //   (tl_c.opcode == ProbeAckData  && b_pending[tl_c.source].tl.opcode inside {ProbeBlock}) ||
  //   (tl_c.opcode inside {Release, ReleaseData})
  // );

  // c.param
  `SEQUENCE(cLegalParam_S, 
    (tl_c.opcode inside {AccessAckData, AccessAck, HintAck} && tl_c.param === '0) ||
    (tl_c.opcode inside {ProbeAck, ProbeAckData, Release, ReleaseData} && tl_c.param inside {[0:5]})
  );

  // TODO: lots of copy/paste from A channel from here on. Can this be tidied?

  // c.size: we expect a certain number of beats in burst messages.
  `SEQUENCE(cNumBeats_S,
    `IMPLIES(cHasPayload_S, 
      c_pending[tl_c.source].beats <= expected_beats(tl_c.size)
    )
  );
  
  // c.address: must be aligned to c.size (for the first beat only).
  `SEQUENCE(cFirstBeat_S, c_pending[tl_c.source].beats == 1);
  `SEQUENCE(cAddrSizeAligned_S, 
    `IMPLIES(cFirstBeat_S, (tl_c.address & ((1 << tl_c.size) - 1)) == '0)
  );

  // c.address: must increment by DataWidthInBytes within multibeat messages.
  `SEQUENCE(cFollowingBeat_S, c_pending[tl_c.source].beats > 1);
  `SEQUENCE(cAddressMultibeatInc_S, 
    `IMPLIES(cFollowingBeat_S,
      tl_c.address == c_pending[tl_c.source].tl.address + 
                      (c_pending[tl_c.source].beats - 1) * DataWidthInBytes
    )
  );

  // Most control signals must remain constant within multibeat messages.
  `SEQUENCE(cMultibeatCtrlConst_S,
    `IMPLIES(cFollowingBeat_S,
      (tl_c.opcode == c_pending[tl_c.source].tl.opcode) &&
      (tl_c.param == c_pending[tl_c.source].tl.param) &&
      (tl_c.size == c_pending[tl_c.source].tl.size) &&
      (tl_c.source == c_pending[tl_c.source].tl.source)
    )
  );

  // c.data: must be known for operations with payloads.
  // Don't use this. The mask is in the corresponding B request, which we don't
  // track. Without a mask, we don't know which lanes of the data to check.
  //`SEQUENCE(cDataKnown_S, `IMPLIES(cHasPayload_S, !$isunknown(tl_c.data)));

  // c.corrupt: only operations with payloads may set c.corrupt to 1.
  `SEQUENCE(cLegalCorrupt_S, `IMPLIES(`NOT cHasPayload_S, !tl_c.corrupt));

  /////////////////////////////////////////
  // D channel                           //
  /////////////////////////////////////////

  `SEQUENCE(dAccepted_S, tl_d_valid && tl_d_ready);

  // d.opcode
  `SEQUENCE(dLegalOpcodeTLUL_S,
    tl_d.opcode inside {AccessAckData, AccessAck}
  );
  `SEQUENCE(dLegalOpcodeTLUH_S,
    dLegalOpcodeTLUL_S `OR tl_d.opcode inside {HintAck}
  );
  `SEQUENCE(dLegalOpcodeTLC_S,
    dLegalOpcodeTLUH_S `OR tl_d.opcode inside {Grant, GrantData, ReleaseAck}
  );

  `SEQUENCE(dHasPayload_S, tl_d.opcode inside {AccessAckData, GrantData});

  // Ensure opcode matches protocol.
  `SEQUENCE(dLegalOpcode_S,
    Protocol == TL_UL ? dLegalOpcodeTLUL_S :
    Protocol == TL_UH ? dLegalOpcodeTLUH_S :
                        dLegalOpcodeTLC_S
  );

  // Ensure opcode matches pending request.
  `SEQUENCE(dMatchingOpcode_S,
    (tl_d.opcode == AccessAckData && a_pending[tl_d.source].tl.opcode inside {Get, ArithmeticData, LogicalData}) ||
    (tl_d.opcode == AccessAck     && a_pending[tl_d.source].tl.opcode inside {PutFullData, PutPartialData}) ||
    (tl_d.opcode == HintAck       && a_pending[tl_d.source].tl.opcode inside {Intent}) ||
    (tl_d.opcode == Grant         && a_pending[tl_d.source].tl.opcode inside {AcquireBlock, AcquirePerm}) ||
    (tl_d.opcode == GrantData     && a_pending[tl_d.source].tl.opcode inside {AcquireBlock}) ||
    (tl_d.opcode == ReleaseAck    && c_pending[tl_d.source].tl.opcode inside {Release, ReleaseData})
  );

  // d.source: each response should have a pending request using same source ID
  // This is only a requirement for Device ports. Host ports may see responses
  // bound for other hosts.
  `SEQUENCE(dRespMustHaveReq_S, 
    (tl_d.opcode != ReleaseAck && a_pending[tl_d.source].pend) ||
    (tl_d.opcode == ReleaseAck && c_pending[tl_d.source].pend)
  );

  // If we have received a complete response, we must also have received
  // a complete request.
  `SEQUENCE(dCompleteResp_S,
    (tl_d.opcode == ReleaseAck) ||
    (a_pending[tl_d.source].resps == (dHasPayload_S ? expected_beats(tl_d.size) : 1))
  );
  `SEQUENCE(dCompleteReq_S,
    (tl_d.opcode != ReleaseAck && a_pending[tl_d.source].beats == expected_beats(a_pending[tl_d.source].tl.size)) ||
    (tl_d.opcode == ReleaseAck && c_pending[tl_d.source].beats == expected_beats(c_pending[tl_d.source].tl.size))
  );
  `SEQUENCE(dCompleteReqResp_S, `IMPLIES(dCompleteResp_S, dCompleteReq_S));

  // Some TileLink topologies allow Host ports to see responses destined for
  // other Host ports. Ignore these.
  `SEQUENCE(dValidResp_S, dAccepted_S `AND dRespMustHaveReq_S);

  // d.param
  `SEQUENCE(dLegalParam_S, 
    (tl_d.opcode inside {AccessAckData, AccessAck, HintAck, ReleaseAck} && tl_d.param === '0) ||
    (tl_d.opcode inside {Grant, GrantData} && tl_d.param inside {[0:2]})
  );

  // d.size: must equal the size of the corresponding request.
  // All requests come from the A channel unless this is a ReleaseAck.
  `SEQUENCE(dSizeEqReqSize_S, 
    (tl_d.opcode != ReleaseAck && tl_d.size === a_pending[tl_d.source].tl.size) ||
    (tl_d.opcode == ReleaseAck && tl_d.size === c_pending[tl_d.source].tl.size)
  );

  // d.size: we expect a certain number of beats in burst messages.
  // There is some redundancy between this and dRespMustHaveReq because the
  // request is cleared when enough responses have arrived.
  `SEQUENCE(dNumBeats_S,
    `IMPLIES(dHasPayload_S, 
      a_pending[tl_d.source].resps <= expected_beats(tl_d.size)
    )
  );

  // d.data: must be known for operations with payloads.
  // The D channel doesn't have a mask, so get it from the corresponding A
  // request. All D operations with payloads are responses to A requests.
  logic [DataWidthInBytes-1:0] d_mask;
  assign d_mask = a_pending[tl_d.source].tl.mask;
  `SEQUENCE(dDataKnown_S, 
    `IMPLIES(dHasPayload_S,
      // no check if this lane mask is inactive
      ((!d_mask[0]) || (d_mask[0] && !$isunknown(tl_d.data[8*0 +: 8]))) &&
      ((!d_mask[1]) || (d_mask[1] && !$isunknown(tl_d.data[8*1 +: 8]))) &&
      ((!d_mask[2]) || (d_mask[2] && !$isunknown(tl_d.data[8*2 +: 8]))) &&
      ((!d_mask[3]) || (d_mask[3] && !$isunknown(tl_d.data[8*3 +: 8]))) &&
      ((!d_mask[4]) || (d_mask[4] && !$isunknown(tl_d.data[8*4 +: 8]))) &&
      ((!d_mask[5]) || (d_mask[5] && !$isunknown(tl_d.data[8*5 +: 8]))) &&
      ((!d_mask[6]) || (d_mask[6] && !$isunknown(tl_d.data[8*6 +: 8]))) &&
      ((!d_mask[7]) || (d_mask[7] && !$isunknown(tl_d.data[8*7 +: 8])))
    )
  );

  // d.corrupt: only operations with payloads may set d.corrupt to 1.
  `SEQUENCE(dLegalCorrupt_S, `IMPLIES(`NOT dHasPayload_S, !tl_d.corrupt));

  // d.denied must be unused for ReleaseAck operations.
  `SEQUENCE(dLegalDenied_S, `IMPLIES(tl_d.opcode == ReleaseAck, tl_d.denied == 0));

  // d.denied implies d.corrupt for AccessAckData and GrantData operations.
  `SEQUENCE(dDeniedImpliesCorrupt_S,
    !(tl_d.opcode inside {AccessAckData, GrantData}) || 
    `IMPLIES(tl_d.denied, tl_d.corrupt)
  );

  /////////////////////////////////////////
  // E channel                           //
  /////////////////////////////////////////

  `SEQUENCE(eAccepted_S, tl_e_valid && tl_e_ready);
  `SEQUENCE(eEnabled_S, Protocol == TL_C);

  // e.opcode
  // There is only one opcode for the E channel, so it does not need to be sent.
  `SEQUENCE(eLegalOpcode_S, 1'b1);  // All "opcodes" are legal

  // Ensure opcode matches pending request.
  `SEQUENCE(eMatchingOpcode_S,
    (tl_e_valid && d_pending[tl_e.sink].tl.opcode inside {Grant, GrantData})
  );

  // e.sink: there must be a pending D grant with the same sink.
  `SEQUENCE(eRespMustHaveReq_S, d_pending[tl_e.sink].pend);

  // Some TileLink topologies allow Device ports to see responses destined for
  // other Device ports. Ignore these.
  `SEQUENCE(eValidResp_S, eAccepted_S `AND eRespMustHaveReq_S);

  // We may only respond to a complete request.
  `SEQUENCE(eCompleteResp_S, eAccepted_S);
  `SEQUENCE(eCompleteReq_S,
    (d_pending[tl_e.sink].tl.opcode == Grant) ||
    (d_pending[tl_e.sink].tl.opcode == GrantData && d_pending[tl_e.sink].beats == expected_beats(d_pending[tl_e.sink].tl.size))
  );
  `SEQUENCE(eCompleteReqResp_S, `IMPLIES(eCompleteResp_S, eCompleteReq_S));

  ///////////////////////////////////
  // Assemble properties and check //
  ///////////////////////////////////

  // For Hosts, all signals coming from the Device side have an assumed property
  if (EndpointType == "Host") begin : gen_host
    // A channel
    `S_ASSERT(aLegalOpcode_A,     `IMPLIES(aAccepted_S, aLegalOpcode_S))
    `S_ASSERT(aLegalParam_A,      `IMPLIES(aAccepted_S, aLegalParam_S))
    `S_ASSERT(aSizeLTEBusWidth_A, `IMPLIES(aAccepted_S, aSizeLTEBusWidth_S))
    `S_ASSERT(aSizeGTEMask_A,     `IMPLIES(aAccepted_S, aSizeGTEMask_S))
    `S_ASSERT(aSizeMatchesMask_A, `IMPLIES(aAccepted_S, aSizeMatchesMask_S))
    `S_ASSERT(aNumBeats_A,        `IMPLIES(aAccepted_S, aNumBeats_S))
    `S_ASSERT(aAddrSizeAligned_A, `IMPLIES(aAccepted_S, aAddrSizeAligned_S))
    `S_ASSERT(aAddrMultibeatInc_A,`IMPLIES(aAccepted_S, aAddressMultibeatInc_S))
    `S_ASSERT(aMultibeatCtrlConst_A,`IMPLIES(aAccepted_S, aMultibeatCtrlConst_S))
    `S_ASSERT(aContigMask_A,      `IMPLIES(aAccepted_S, aContigMask_S))
    `S_ASSERT(aFullMaskUsed_A,    `IMPLIES(aAccepted_S, aFullMaskUsed_S))
    `S_ASSERT(aMaskAligned_A,     `IMPLIES(aAccepted_S, aMaskAligned_S))
    `S_ASSERT(aDataKnown_A,       `IMPLIES(aAccepted_S, aDataKnown_S))
    `S_ASSERT(aLegalCorrupt_A,    `IMPLIES(aAccepted_S, aLegalCorrupt_S))

    // B channel
    `S_ASSUME(bEnabled_M,         `IMPLIES(bAccepted_S, bEnabled_S))
    `S_ASSUME(bLegalOpcode_M,     `IMPLIES(bAccepted_S, bLegalOpcode_S))
    `S_ASSUME(bLegalParam_M,      `IMPLIES(bAccepted_S, bLegalParam_S))
    `S_ASSUME(bSizeGTEMask_M,     `IMPLIES(bAccepted_S, bSizeGTEMask_S))
    `S_ASSUME(bContigMask_M,      `IMPLIES(bAccepted_S, bContigMask_S))
    `S_ASSUME(bFullMaskUsed_M,    `IMPLIES(bAccepted_S, bFullMaskUsed_S))
    `S_ASSUME(bMaskAligned_M,     `IMPLIES(bAccepted_S, bMaskAligned_S))
    `S_ASSUME(bDataKnown_M,       `IMPLIES(bAccepted_S, bDataKnown_S))
    `S_ASSUME(bLegalCorrupt_M,    `IMPLIES(bAccepted_S, bLegalCorrupt_S))

    // C channel
    `S_ASSERT(cEnabled_A,         `IMPLIES(cAccepted_S, cEnabled_S))
    `S_ASSERT(cLegalOpcode_A,     `IMPLIES(cAccepted_S, cLegalOpcode_S))
    `S_ASSERT(cLegalParam_A,      `IMPLIES(cAccepted_S, cLegalParam_S))
    `S_ASSERT(cNumBeats_A,        `IMPLIES(cAccepted_S, cNumBeats_S))
    `S_ASSERT(cAddrSizeAligned_A, `IMPLIES(cAccepted_S, cAddrSizeAligned_S))
    `S_ASSERT(cAddrMultibeatInc_A,`IMPLIES(cAccepted_S, cAddressMultibeatInc_S))
    `S_ASSERT(cMultibeatCtrlConst_A,`IMPLIES(cAccepted_S, cMultibeatCtrlConst_S))
    // `S_ASSERT(cDataKnown_A,       `IMPLIES(cAccepted_S, cDataKnown_S))
    `S_ASSERT(cLegalCorrupt_A,    `IMPLIES(cAccepted_S, cLegalCorrupt_S))

    // D channel
    // Host ports may see responses sent elsewhere. Use dValidResp precondition
    // to ignore them because we have no access to the matching requests.
    `S_ASSUME(dLegalOpcode_M,     `IMPLIES(dValidResp_S, dLegalOpcode_S))
    `S_ASSUME(dMatchingOpcode_M,  `IMPLIES(dValidResp_S, dMatchingOpcode_S))
    `S_ASSUME(dLegalParam_M,      `IMPLIES(dValidResp_S, dLegalParam_S))
    // `S_ASSUME(dRespMustHaveReq_M,  `IMPLIES(dAccepted_S, dRespMustHaveReq_S))
    `S_ASSUME(dCompleteReqResp_M, `IMPLIES(dValidResp_S, dCompleteReqResp_S))
    `S_ASSUME(dSizeEqReqSize_M,   `IMPLIES(dValidResp_S, dSizeEqReqSize_S))
    `S_ASSUME(dNumBeats_M,        `IMPLIES(dValidResp_S, dNumBeats_S))
    `S_ASSUME(dDataKnown_M,       `IMPLIES(dValidResp_S, dDataKnown_S))
    `S_ASSUME(dLegalCorrupt_M,    `IMPLIES(dValidResp_S, dLegalCorrupt_S))
    `S_ASSUME(dLegalDenied_M,     `IMPLIES(dValidResp_S, dLegalDenied_S))
    `S_ASSUME(dDeniedImpliesCorrupt_M, `IMPLIES(dValidResp_S, dDeniedImpliesCorrupt_S))
  
    // E channel
    `S_ASSERT(eEnabled_A,         `IMPLIES(eAccepted_S, eEnabled_S))
    `S_ASSERT(eLegalOpcode_A,     `IMPLIES(eAccepted_S, eLegalOpcode_S))
    `S_ASSERT(eMatchingOpcode_A,  `IMPLIES(eAccepted_S, eMatchingOpcode_S))
    `S_ASSERT(eRespMustHaveReq_A, `IMPLIES(eAccepted_S, eRespMustHaveReq_S))
    `S_ASSERT(eCompleteReqResp_A, `IMPLIES(eAccepted_S, eCompleteReqResp_S))

  // For Devices, all signals coming from the Host side have an assumed property
  end else if (EndpointType == "Device") begin : gen_device
    // A channel
    `S_ASSUME(aLegalOpcode_M,     `IMPLIES(aAccepted_S, aLegalOpcode_S))
    `S_ASSUME(aLegalParam_M,      `IMPLIES(aAccepted_S, aLegalParam_S))
    `S_ASSUME(aSizeLTEBusWidth_M, `IMPLIES(aAccepted_S, aSizeLTEBusWidth_S))
    `S_ASSUME(aSizeGTEMask_M,     `IMPLIES(aAccepted_S, aSizeGTEMask_S))
    `S_ASSUME(aSizeMatchesMask_M, `IMPLIES(aAccepted_S, aSizeMatchesMask_S))
    `S_ASSUME(aNumBeats_M,        `IMPLIES(aAccepted_S, aNumBeats_S))
    `S_ASSUME(aAddrSizeAligned_M, `IMPLIES(aAccepted_S, aAddrSizeAligned_S))
    `S_ASSUME(aAddrMultibeatInc_M,`IMPLIES(aAccepted_S, aAddressMultibeatInc_S))
    `S_ASSUME(aMultibeatCtrlConst_M,`IMPLIES(aAccepted_S, aMultibeatCtrlConst_S))
    `S_ASSUME(aContigMask_M,      `IMPLIES(aAccepted_S, aContigMask_S))
    `S_ASSUME(aFullMaskUsed_M,    `IMPLIES(aAccepted_S, aFullMaskUsed_S))
    `S_ASSUME(aMaskAligned_M,     `IMPLIES(aAccepted_S, aMaskAligned_S))
    `S_ASSUME(aDataKnown_M,       `IMPLIES(aAccepted_S, aDataKnown_S))
    `S_ASSUME(aLegalCorrupt_M,    `IMPLIES(aAccepted_S, aLegalCorrupt_S))

    // B channel
    `S_ASSERT(bEnabled_A,         `IMPLIES(bAccepted_S, bEnabled_S))
    `S_ASSERT(bLegalOpcode_A,     `IMPLIES(bAccepted_S, bLegalOpcode_S))
    `S_ASSERT(bLegalParam_A,      `IMPLIES(bAccepted_S, bLegalParam_S))
    `S_ASSERT(bSizeGTEMask_A,     `IMPLIES(bAccepted_S, bSizeGTEMask_S))
    `S_ASSERT(bContigMask_A,      `IMPLIES(bAccepted_S, bContigMask_S))
    `S_ASSERT(bFullMaskUsed_A,    `IMPLIES(bAccepted_S, bFullMaskUsed_S))
    `S_ASSERT(bMaskAligned_A,     `IMPLIES(bAccepted_S, bMaskAligned_S))
    `S_ASSERT(bDataKnown_A,       `IMPLIES(bAccepted_S, bDataKnown_S))
    `S_ASSERT(bLegalCorrupt_A,    `IMPLIES(bAccepted_S, bLegalCorrupt_S))

    // C channel
    `S_ASSUME(cEnabled_M,         `IMPLIES(cAccepted_S, cEnabled_S))
    `S_ASSUME(cLegalOpcode_M,     `IMPLIES(cAccepted_S, cLegalOpcode_S))
    `S_ASSUME(cLegalParam_M,      `IMPLIES(cAccepted_S, cLegalParam_S))
    `S_ASSUME(cNumBeats_M,        `IMPLIES(cAccepted_S, cNumBeats_S))
    `S_ASSUME(cAddrSizeAligned_M, `IMPLIES(cAccepted_S, cAddrSizeAligned_S))
    `S_ASSUME(cAddrMultibeatInc_M,`IMPLIES(cAccepted_S, cAddressMultibeatInc_S))
    `S_ASSUME(cMultibeatCtrlConst_M,`IMPLIES(cAccepted_S, cMultibeatCtrlConst_S))
    // `S_ASSUME(cDataKnown_M,       `IMPLIES(cAccepted_S, cDataKnown_S))
    `S_ASSUME(cLegalCorrupt_M,    `IMPLIES(cAccepted_S, cLegalCorrupt_S))

    // D channel
    `S_ASSERT(dLegalOpcode_A,     `IMPLIES(dAccepted_S, dLegalOpcode_S))
    `S_ASSERT(dMatchingOpcode_A,  `IMPLIES(dAccepted_S, dMatchingOpcode_S))
    `S_ASSERT(dLegalParam_A,      `IMPLIES(dAccepted_S, dLegalParam_S))
    `S_ASSERT(dRespMustHaveReq_A, `IMPLIES(dAccepted_S, dRespMustHaveReq_S))
    `S_ASSERT(dCompleteReqResp_A, `IMPLIES(dAccepted_S, dCompleteReqResp_S))
    `S_ASSERT(dSizeEqReqSize_A,   `IMPLIES(dAccepted_S, dSizeEqReqSize_S))
    `S_ASSERT(dNumBeats_A,        `IMPLIES(dAccepted_S, dNumBeats_S))
    `S_ASSERT(dDataKnown_A,       `IMPLIES(dAccepted_S, dDataKnown_S))
    `S_ASSERT(dLegalCorrupt_A,    `IMPLIES(dAccepted_S, dLegalCorrupt_S))
    `S_ASSERT(dLegalDenied_A,     `IMPLIES(dAccepted_S, dLegalDenied_S))
    `S_ASSERT(dDeniedImpliesCorrupt_A, `IMPLIES(dAccepted_S, dDeniedImpliesCorrupt_S))
  
    // E channel
    // Device ports may see responses sent elsewhere. Use eValidResp precondition
    // to ignore them because we have no access to the matching requests.
    `S_ASSUME(eEnabled_M,         `IMPLIES(eValidResp_S, eEnabled_S))
    `S_ASSUME(eLegalOpcode_M,     `IMPLIES(eValidResp_S, eLegalOpcode_S))
    `S_ASSUME(eMatchingOpcode_M,  `IMPLIES(eValidResp_S, eMatchingOpcode_S))
    // `S_ASSUME(eRespMustHaveReq_M, `IMPLIES(eAccepted_S, eRespMustHaveReq_S))
    `S_ASSUME(eCompleteReqResp_M, `IMPLIES(eValidResp_S, eCompleteReqResp_S))

  end else begin : gen_unknown
    initial begin : p_unknown
      `S_ASSERT_I(unknownConfig_A, 0 == 1)
    end
  end

  initial begin : p_dbw
    // Widths up to 64bit / 8 Byte are supported
    `S_ASSERT_I(TlDbw_A, DataWidth <= 64)
  end

  // Make sure all "pending" bits are 0 at the end of the sim
  for (genvar ii = 0; ii < 2**SourceWidth; ii++) begin : gen_assert_final_abc
    `S_ASSERT_FINAL(aNoOutstandingReqsAtEndOfSim_A, (a_pending[ii].pend == 0))
    // `S_ASSERT_FINAL(bNoOutstandingReqsAtEndOfSim_A, (b_pending[ii].pend == 0))
    `S_ASSERT_FINAL(cNoOutstandingReqsAtEndOfSim_A, (c_pending[ii].pend == 0))
  end
  for (genvar ii = 0; ii < 2**SinkWidth; ii++) begin : gen_assert_final_d
    `S_ASSERT_FINAL(dNoOutstandingReqsAtEndOfSim_A, (d_pending[ii].pend == 0))
  end

  ////////////////////////////////////
  // Additional checks for X values //
  ////////////////////////////////////

  // All signals should be known when valid == 1 (except data in unused lanes).
  // This also covers ASSERT_KNOWN of the valid signals.
  `S_ASSERT_KNOWN_IF(aKnown_A, 
    {tl_a.opcode, tl_a.param, tl_a.size, tl_a.source, tl_a.address, tl_a.mask, tl_a.corrupt},
    tl_a_valid)
  `S_ASSERT_KNOWN_IF(bKnown_A, 
    {tl_b.opcode, tl_b.param, tl_b.size, tl_b.source, tl_b.address, tl_b.mask, tl_b.corrupt},
    tl_b_valid)
  `S_ASSERT_KNOWN_IF(cKnown_A, 
    {tl_c.opcode, tl_c.param, tl_c.size, tl_c.source, tl_c.address, tl_c.corrupt},
    tl_c_valid)
  `S_ASSERT_KNOWN_IF(dKnown_A, 
    {tl_d.opcode, tl_d.param, tl_d.size, tl_d.source, tl_d.sink, tl_d.denied, tl_d.corrupt}, 
    tl_d_valid)
  `S_ASSERT_KNOWN_IF(eKnown_A, tl_e.sink, tl_e_valid)

  //  Make sure ready is not X after reset
  `S_ASSERT_KNOWN(aReadyKnown_A, tl_a_ready)
  `S_ASSERT_KNOWN(bReadyKnown_A, tl_b_ready)
  `S_ASSERT_KNOWN(cReadyKnown_A, tl_c_ready)
  `S_ASSERT_KNOWN(dReadyKnown_A, tl_d_ready)
  `S_ASSERT_KNOWN(eReadyKnown_A, tl_e_ready)


  ////////////////////////////////////
  // SVA coverage                   //
  ////////////////////////////////////

  // Back-to-back messages are sent on a channel
  // TODO: multibeat messages shouldn't count
  `define BACK_TO_BACK(CHANNEL) \
    `SEQUENCE(``CHANNEL``BackToBack_S, \
      prev_tl_``CHANNEL``_valid && prev_tl_``CHANNEL``_ready && tl_``CHANNEL``_valid \
    ); \
    `S_COVER(``CHANNEL``BackToBack_C, ``CHANNEL``BackToBack_S)

  // A valid signal is deasserted before it is accepted by the recipient.
  // TODO: check that this is doing what we expect
  `define VALID_NOT_ACCEPTED(CHANNEL) \
    `SEQUENCE(``CHANNEL``ValidNotAccepted_S, \
      prev_tl_``CHANNEL``_valid && !prev_tl_``CHANNEL``_ready && !tl_``CHANNEL``_valid \
    ); \
    `S_COVER(``CHANNEL``ValidNotAccepted_C, ``CHANNEL``ValidNotAccepted_S)
  
  // Content is changed without being accepted.
  // TODO: check that this is doing what we expect
  `define CHANGED_WITHOUT_ACCEPTED(CHANNEL, NAME) \
    `SEQUENCE(``CHANNEL``_``NAME``ChangedNotAccepted_S, \
      tl_``CHANNEL``_valid && prev_declined_``CHANNEL``_valid && \
      prev_declined_``CHANNEL``.``NAME`` != tl_``CHANNEL``.``NAME`` \
    ); \
    `S_COVER(``CHANNEL``_``NAME``ChangedNotAccepted_C, ``CHANNEL``_``NAME``ChangedNotAccepted_S)

  // Consecutive messages on the same channel use the same value.
  // TODO: multibeat messages shouldn't count.
  `define CONSECUTIVE_MESSAGES_REPEAT(CHANNEL, NAME) \
    `SEQUENCE(``CHANNEL``_``NAME``Repeated_S, \
      tl_``CHANNEL``_valid && prev_accepted_``CHANNEL``_valid && \
      tl_``CHANNEL``.``NAME`` == prev_accepted_``CHANNEL``.``NAME`` \
    ); \
    `S_COVER(``CHANNEL``_``NAME``Repeated_C, ``CHANNEL``_``NAME``Repeated_S)
  
  // Check that the `corrupt` bit is used.
  `define CORRUPT_BIT_USED(CHANNEL) \
    `S_COVER(``CHANNEL``Corrupt_C, tl_``CHANNEL``.corrupt)

  // Check that the `denied` bit is used.
  `define DENIED_BIT_USED(CHANNEL) \
    `S_COVER(``CHANNEL``Denied_C, tl_``CHANNEL``.denied)
  
  // For every channel as a whole, we would like to see:
  //   * Back-to-back messages (no period where valid is low)
  //   * Valid messages being deasserted before they have been accepted
  `define STANDARD_CHANNEL_COVERAGE(CHANNEL) \
    `BACK_TO_BACK(CHANNEL) \
    `VALID_NOT_ACCEPTED(CHANNEL)
  
  // For every field of every channel, we would like to see:
  //   * The value {changes, stays the same} in consecutive messages
  //   * The value {changes, stays the same} while waiting to be accepted
  `define STANDARD_FIELD_COVERAGE(CHANNEL, NAME) \
    `CONSECUTIVE_MESSAGES_REPEAT(CHANNEL, NAME) \
    `CHANGED_WITHOUT_ACCEPTED(CHANNEL, NAME)

  `STANDARD_CHANNEL_COVERAGE(a)
  `STANDARD_FIELD_COVERAGE(a, opcode)
  `STANDARD_FIELD_COVERAGE(a, param)
  `STANDARD_FIELD_COVERAGE(a, size)
  `STANDARD_FIELD_COVERAGE(a, source)
  `STANDARD_FIELD_COVERAGE(a, address)
  `STANDARD_FIELD_COVERAGE(a, mask)
  `STANDARD_FIELD_COVERAGE(a, corrupt)
  `STANDARD_FIELD_COVERAGE(a, data)
  `CORRUPT_BIT_USED(a)

  `STANDARD_CHANNEL_COVERAGE(d)
  `STANDARD_FIELD_COVERAGE(d, opcode)
  `STANDARD_FIELD_COVERAGE(d, param)
  `STANDARD_FIELD_COVERAGE(d, size)
  `STANDARD_FIELD_COVERAGE(d, source)
  `STANDARD_FIELD_COVERAGE(d, sink)
  `STANDARD_FIELD_COVERAGE(d, denied)
  `STANDARD_FIELD_COVERAGE(d, corrupt)
  `STANDARD_FIELD_COVERAGE(d, data)
  `CORRUPT_BIT_USED(d)
  `DENIED_BIT_USED(d)

  if (Protocol == TL_C) begin : gen_tlc_channel_cov
    `STANDARD_CHANNEL_COVERAGE(b)
    `STANDARD_FIELD_COVERAGE(b, opcode)
    `STANDARD_FIELD_COVERAGE(b, param)
    `STANDARD_FIELD_COVERAGE(b, size)
    `STANDARD_FIELD_COVERAGE(b, source)
    `STANDARD_FIELD_COVERAGE(b, address)
    `STANDARD_FIELD_COVERAGE(b, mask)
    `STANDARD_FIELD_COVERAGE(b, corrupt)
    `STANDARD_FIELD_COVERAGE(b, data)
    `CORRUPT_BIT_USED(b)

    `STANDARD_CHANNEL_COVERAGE(c)
    `STANDARD_FIELD_COVERAGE(c, opcode)
    `STANDARD_FIELD_COVERAGE(c, param)
    `STANDARD_FIELD_COVERAGE(c, size)
    `STANDARD_FIELD_COVERAGE(c, source)
    `STANDARD_FIELD_COVERAGE(c, address)
    `STANDARD_FIELD_COVERAGE(c, corrupt)
    `STANDARD_FIELD_COVERAGE(c, data)
    `CORRUPT_BIT_USED(c)

    `STANDARD_CHANNEL_COVERAGE(e)
    `STANDARD_FIELD_COVERAGE(e, sink)
  end

  `undef BACK_TO_BACK
  `undef VALID_NOT_ACCEPTED
  `undef CHANGED_WITHOUT_ACCEPTED
  `undef CONSECUTIVE_MESSAGES_REPEAT
  `undef CORRUPT_BIT_USED
  `undef DENIED_BIT_USED
  `undef STANDARD_CHANNEL_COVERAGE
  `undef STANDARD_FIELD_COVERAGE


  // Look for simultaneous messages on all combinations of channels.
  // Covergroups aren't supported by Verilator, so pack values into a signal
  // instead.
  logic [1:0] tluh_accepted;  // Also TL-UL.
  logic [4:0] tlc_accepted;

  assign tlc_accepted =  {aAccepted_S, bAccepted_S, cAccepted_S, dAccepted_S,
                          eAccepted_S};
  assign tluh_accepted = {aAccepted_S, dAccepted_S};

  // TODO: current macro can't accept multibit properties.
  if (Protocol == TL_C) begin : gen_tlc_simultaneous_cov
    `S_COVER(tlc_simultaneous, tlc_accepted);
  end else begin : gen_tluh_simultaneous_cov
    `S_COVER(tluh_simultaneous, tluh_accepted);
  end

endmodule