// vmem 상의 원소별 벡터 연산 (등록 읽기 -> read-ahead):
//   op=0 ADD : dst[i] = sat16( a[i] + b[i] )   (잔차 덧셈)
//   op=1 RELU: dst[i] = max(0, a[i])           (MLP 활성화)
// ADD는 벡터 a를 로컬 캐시에 읽어들인 뒤(read-ahead) b를 스트리밍하며 a+b를 씀.
// RELU는 a를 스트리밍하며 max(0,a)를 씀. cnt는 최대 MLP 폭(96). (SystemVerilog)
module vecop (
    input  logic        clk,
    input  logic        resetn,
    input  logic        start,
    input  logic        op,            // 0=ADD, 1=RELU
    input  logic [9:0]  a_base,
    input  logic [9:0]  b_base,
    input  logic [9:0]  dst_base,
    input  logic [6:0]  cnt,
    output logic [9:0]  v_raddr,
    input  logic signed [15:0] v_rdata,
    output logic        v_we,
    output logic [9:0]  v_waddr,
    output logic signed [15:0] v_wdata,
    output logic        busy,
    output logic        done
);
    typedef enum logic [1:0] { S_IDLE, S_LOADA, S_COMB } state_t;
    state_t    st;
    logic [6:0]  fi, fi_d;
    logic        feeding, vld;
    logic signed [15:0] areg [0:95];

    assign v_raddr = (st == S_LOADA) ? (a_base + {3'd0, fi})    // ADD: a 캐시
                   : op              ? (a_base + {3'd0, fi})    // RELU: a 읽기
                   :                   (b_base + {3'd0, fi});   // ADD: b 읽기

    wire signed [16:0] add = $signed(areg[fi_d[6:0]]) + $signed(v_rdata);
    wire signed [15:0] addsat =
        (add > 17'sd32767) ? 16'sd32767 : (add < -17'sd32768) ? -16'sd32768 : add[15:0];
    wire signed [15:0] reluv = v_rdata[15] ? 16'sd0 : v_rdata;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            st <= S_IDLE; busy <= 0; done <= 0; v_we <= 0; feeding <= 0; vld <= 0;
        end else begin
            done <= 0; v_we <= 0;
            fi_d <= fi; vld <= feeding;
            unique case (st)
                S_IDLE: if (start) begin
                    busy <= 1; fi <= 0; feeding <= 1;
                    st <= op ? S_COMB : S_LOADA;   // RELU는 a-캐시를 건너뜀
                end
                // ADD: 벡터 a 캐시
                S_LOADA: begin
                    if (vld) areg[fi_d[6:0]] <= v_rdata;
                    if (feeding) begin
                        if (fi == cnt - 1) feeding <= 0;
                        else fi <= fi + 1;
                    end
                    if (vld && fi_d == cnt - 1) begin fi <= 0; feeding <= 1; st <= S_COMB; end
                end
                // ADD: b 스트리밍, a+b 쓰기 ; RELU: a 스트리밍, relu(a) 쓰기
                S_COMB: begin
                    if (vld) begin
                        v_we <= 1; v_waddr <= dst_base + {3'd0, fi_d};
                        v_wdata <= op ? reluv : addsat;
                    end
                    if (feeding) begin
                        if (fi == cnt - 1) feeding <= 0;
                        else fi <= fi + 1;
                    end
                    if (vld && fi_d == cnt - 1) begin busy <= 0; done <= 1; st <= S_IDLE; end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
