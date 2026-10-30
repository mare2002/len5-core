#if !defined(ALU_TB_COMPONENTS_HH_)
#define ALU_TB_COMPONENTS_HH_

#include <verilated.h>
#include "Valu_tb.h"

class ReqTx
{
public:
    vluint64_t rs1;
    vluint64_t rs2;
    vluint8_t alu_ctl;
    vluint8_t valid;
    vluint8_t flush;
    vluint32_t rob_idx;

    ReqTx();
    ~ReqTx();
};

class RspTx
{
public:
    vluint8_t valid;
    vluint8_t ready;
    vluint64_t res;

    RspTx();
    ~RspTx();
};

class Drv
{
private:
    Valu_tb *dut;

public:
    Drv(Valu_tb *dut);
    ~Drv();

    void drive(ReqTx *req);
};

class Scb
{
private:
    std::deque<ReqTx *> req_q;
    std::deque<RspTx *> rsp_q;
    unsigned int tx_num;
    unsigned int err_num;

    void checkRes();

public:
    Scb();
    ~Scb();

    void writeReq(ReqTx *req);
    void writeRsp(RspTx *rsp);
    void flush();

    unsigned int getTxNum();
    unsigned int getErrNum();
    int isDone();
};

class ReqMonitor
{
private:
    Valu_tb *dut;
    Scb *scb;
    ReqTx *req;
    uint8_t req_busy;

public:
    ReqMonitor(Valu_tb *dut, Scb *scb);
    ~ReqMonitor();

    void monitor();
};

class RspMonitor
{
private:
    Valu_tb *dut;
    Scb *scb;

public:
    RspMonitor(Valu_tb *dut, Scb *scb);
    ~RspMonitor();

    void monitor();
};

#endif // ALU_TB_COMPONENTS_HH_
