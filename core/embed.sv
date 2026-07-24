// 임베딩 조회: emb[i] = sat16( tok_embed[token][i] + pos_embed[pos][i] ),
// i = 0..N_EMBED-1, vmem[dst_base+i]에 씀. 토큰/위치 임베딩 ROM (Q5.11).
// (SystemVerilog)
module embed #(
    parameter int N_EMBED = 24
) (
    input  logic        clk,
    input  logic        resetn,
    input  logic        start,
    input  logic [4:0]  token,
    input  logic [3:0]  pos,
    input  logic [9:0]  dst_base,
    output logic        v_we,
    output logic [9:0]  v_waddr,
    output logic signed [15:0] v_wdata,
    output logic        busy,
    output logic        done
);
    // 임베딩 ROM을 조합 case 함수로($readmemh가 아님: XST 14.7이 작은 $readmemh 분산
    // ROM을 0으로 만듦). tok = 27x24, pos = 16x24, 행 우선.
`include "tok_emb.vh"
`include "pos_emb.vh"

    typedef enum logic { E_IDLE, E_RUN } estate_t;
    estate_t   st;
    logic [6:0]  i;
    logic [9:0]  tbase, pbase;

    wire signed [16:0] sum = $signed(tok_emb(tbase + {3'd0, i})) + $signed(pos_emb(pbase + {3'd0, i}));
    wire signed [15:0] esat =
        (sum >  17'sd32767) ? 16'sd32767 : (sum < -17'sd32768) ? -16'sd32768 : sum[15:0];

    always_ff @(posedge clk) begin
        if (!resetn) begin st <= E_IDLE; busy <= 0; done <= 0; v_we <= 0; end
        else begin
            done <= 0; v_we <= 0;
            unique case (st)
                E_IDLE: if (start) begin
                    busy <= 1; i <= 0;
                    tbase <= token * N_EMBED;   // <= 26*24 = 624
                    pbase <= pos * N_EMBED;      // <= 15*24 = 360
                    st <= E_RUN;
                end
                E_RUN: begin
                    v_we <= 1; v_waddr <= dst_base + i; v_wdata <= esat;
                    if (i == N_EMBED - 1) begin busy <= 0; done <= 1; st <= E_IDLE; end
                    else i <= i + 1;
                end
            endcase
        end
    end
endmodule
