// Elementwise vector op over vmem (registered read -> read-ahead):
//   op=0 ADD : dst[i] = sat16( a[i] + b[i] )   (residual adds)
//   op=1 RELU: dst[i] = max(0, a[i])           (MLP activation)
// ADD reads vector a into a local cache (read-ahead), then streams b and writes a+b.
// RELU streams a and writes max(0,a). cnt up to MLP width (96). (SystemVerilog)
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

    assign v_raddr = (st == S_LOADA) ? (a_base + {3'd0, fi})    // ADD: cache a
                   : op              ? (a_base + {3'd0, fi})    // RELU: read a
                   :                   (b_base + {3'd0, fi});   // ADD: read b

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
                    st <= op ? S_COMB : S_LOADA;   // RELU skips the a-cache
                end
                // ADD: cache vector a
                S_LOADA: begin
                    if (vld) areg[fi_d[6:0]] <= v_rdata;
                    if (feeding) begin
                        if (fi == cnt - 1) feeding <= 0;
                        else fi <= fi + 1;
                    end
                    if (vld && fi_d == cnt - 1) begin fi <= 0; feeding <= 1; st <= S_COMB; end
                end
                // ADD: stream b, write a+b ; RELU: stream a, write relu(a)
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
