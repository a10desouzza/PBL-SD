`timescale 1ns / 1ps
module elm_accel (
    input  wire        clk,
    input  wire        reset_n,

    // Avalon MM Slave
    input  wire [3:0]  avs_address,
    input  wire        avs_write,
    input  wire [31:0] avs_writedata,
    input  wire        avs_read,
    output reg  [31:0] avs_readdata,
    output wire        avs_waitrequest,

    // SAÍDAS DA PLACA DE1-SoC
    output reg  [6:0]  hex3, hex2, hex1, hex0,   // BUSY / DONE / ERRO
    output reg  [3:0]  ledr_pred                 // predição em binário
);

assign avs_waitrequest = 1'b0;

// ===============================================
// Registradores MMIO
// ===============================================
reg [31:0] addr_reg, data_reg; // Nota: Você precisa implementar a lógica de escrita nestes registradores
reg [31:0] cycles_reg;

// Flags
reg img_ok, w_ok, b_ok, beta_ok;

// Sinais de write para as memórias IP
reg img_write, w_write, b_write, beta_write;

// ===============================================
// Memórias IP (RAM:1-PORT)
// ===============================================
wire [15:0] img_q, W_q, b_q, beta_q;

ram_img_784x16     mem_img_inst  (.clock(clk), .address(addr_reg[9:0]),  .data(data_reg[15:0]), .wren(img_write),   .q(img_q));
ram_W_100352x16    mem_W_inst    (.clock(clk), .address(addr_reg[16:0]), .data(data_reg[15:0]), .wren(w_write),     .q(W_q));
ram_b_128x16       mem_b_inst    (.clock(clk), .address(addr_reg[6:0]),  .data(data_reg[15:0]), .wren(b_write),     .q(b_q));
ram_beta_1280x16   mem_beta_inst (.clock(clk), .address(addr_reg[10:0]), .data(data_reg[15:0]), .wren(beta_write),  .q(beta_q));

// ===============================================
// FSM
// ===============================================
localparam DONE  = 2'b00;
localparam BUSY  = 2'b01;
localparam ERROR = 2'b10;

reg [1:0] estado_atual;
reg [1:0] proximo_estado;
reg [2:0] opcode;
reg [31:0] contador_ciclos;
reg [3:0]  pred;

// ===============================================
// 1. Lógica Sequencial (ÚNICO driver para registros sincronizados)
// ===============================================
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        estado_atual    <= DONE;
        contador_ciclos <= 32'd0;
        cycles_reg      <= 32'd0;
        img_ok <= 0; w_ok <= 0; b_ok <= 0; beta_ok <= 0;
        pred            <= 4'd0;
        opcode          <= 3'd0;
        
        // Zera os sinais de escrita
        img_write <= 0; w_write <= 0; b_write <= 0; beta_write <= 0;
    end else begin
        // Atualiza estado
        estado_atual <= proximo_estado;

        // Atualiza contador de ciclos
        if (estado_atual == BUSY)
            contador_ciclos <= contador_ciclos + 1'b1;
        else
            contador_ciclos <= 32'd0;

        // Captura o opcode no modo DONE quando há uma escrita
        if (estado_atual == DONE && avs_write && avs_address == 4'h0) begin
            opcode <= avs_writedata[2:0];
        end

        // Pulsos de escrita por padrão em 0 (evita latches e mantém em apenas 1 ciclo)
        img_write <= 1'b0; w_write <= 1'b0; b_write <= 1'b0; beta_write <= 1'b0;

        // Execução de STORE e START baseado no estado atual
        if (estado_atual == BUSY) begin
            case (opcode)
                3'b001: if (addr_reg < 784)    begin img_write <= 1'b1;  img_ok <= 1'b1;  end
                3'b010: if (addr_reg < 100352) begin w_write <= 1'b1;    w_ok <= 1'b1;    end
                3'b011: if (addr_reg < 128)    begin b_write <= 1'b1;    b_ok <= 1'b1;    end
                3'b100: if (addr_reg < 1280)   begin beta_write <= 1'b1; beta_ok <= 1'b1; end
                3'b101: begin
                    if (img_ok && w_ok && b_ok && beta_ok) begin
                        cycles_reg <= contador_ciclos;
                        pred <= 4'd5; // placeholder
                    end
                end
            endcase
        end
    end
end

// ===============================================
// 2. Lógica Combinacional FSM - Apenas próximo estado
// ===============================================
always @(*) begin
    proximo_estado = estado_atual;   // default

    case (estado_atual)
        DONE: begin
            if (avs_write && avs_address == 4'h0) begin
                case (avs_writedata[2:0])
                    3'b001, 3'b010, 3'b011, 3'b100, 3'b101: proximo_estado = BUSY;
                    3'b000: proximo_estado = DONE;   // RESET
                    default: proximo_estado = ERROR;
                endcase
            end
        end

        BUSY: begin
            // Como as operações de STORE terminam em 1 ciclo (graças à execução sequencial acima),
            // podemos avaliar o opcode aqui para decidir se volta pra DONE ou vai pra ERROR
            case (opcode)
                3'b001: proximo_estado = (addr_reg < 784)    ? DONE : ERROR;
                3'b010: proximo_estado = (addr_reg < 100352) ? DONE : ERROR;
                3'b011: proximo_estado = (addr_reg < 128)    ? DONE : ERROR;
                3'b100: proximo_estado = (addr_reg < 1280)   ? DONE : ERROR;
                3'b101: proximo_estado = (img_ok && w_ok && b_ok && beta_ok) ? DONE : ERROR;
                default: proximo_estado = DONE;
            endcase
        end

        ERROR: begin
            if (avs_write && avs_address == 4'h0 && avs_writedata[2:0] == 3'b000)
                proximo_estado = DONE;
        end

        default: proximo_estado = DONE;
    endcase
end

// ===============================================
// DISPLAYS 7 SEGMENTOS
// ===============================================
always @(*) begin
    case (estado_atual)
        BUSY: begin
            hex3 = 7'b1000011; // B
            hex2 = 7'b1000001; // U
            hex1 = 7'b0010010; // S
            hex0 = 7'b1100111; // Y
        end
        DONE: begin
            hex3 = 7'b1000001; // D
            hex2 = 7'b1000000; // O
            hex1 = 7'b1001000; // N
            hex0 = 7'b1000110; // E
        end
        ERROR: begin
            hex3 = 7'b1000110; // E
            hex2 = 7'b0000100; // r
            hex1 = 7'b0000100; // r
            hex0 = 7'b1000000; // O
        end
        default: begin
            hex3 = 7'b1111111; hex2 = 7'b1111111;
            hex1 = 7'b1111111; hex0 = 7'b1111111;
        end
    endcase
end

// ===============================================
// LEDs com resultado da inferência
// ===============================================
always @(*) begin
    ledr_pred = pred;
end

// ===============================================
// Leitura Avalon (Corrigido para evitar Latches)
// ===============================================
always @(*) begin
    avs_readdata = 32'h0; // Força um default para não gerar Latch
    case (avs_address)
        4'h3: begin // STATUS
            case (estado_atual)
                DONE:  avs_readdata = {28'b0, 4'b0001} | {28'b0, pred};
                BUSY:  avs_readdata = {28'b0, 4'b0000} | {28'b0, pred};
                ERROR: avs_readdata = {28'b0, 4'b0010} | {28'b0, pred};
                default: avs_readdata = 32'h0;
            endcase
        end
        4'h4: avs_readdata = {28'b0, pred};
        4'h5: avs_readdata = cycles_reg;
        default: avs_readdata = 32'h0;
    endcase
end

endmodule