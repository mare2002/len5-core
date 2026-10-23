// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Synthetic confidence and coverage fixtures adapted from EJU; no RTL execution.
#include "fetch_mem_scoreboard.hh"
#include "tb_macros.hh"
#include <filesystem>
TbLogger logger;
using namespace len5::fetchmem;
int main(int argc,char** argv){if(argc!=3)return 2;const std::string dir=argv[1],kind=argv[2];
    if(kind=="coverage"){
        for(unsigned n:{1u,2u,4u,8u}){Config c;c.lanes=n;Coverage cov(c);for(unsigned lane=0;lane<n;++lane){Sample s;s.phase="pre";s.cycle=lane;s.stimulus.start=0x100+lane*4;s.observed.fetch_valid=s.observed.grant=s.actual.request_valid=true;s.actual.fetch_ready=true;s.transition.k=true;
                for(unsigned k=0;k<n;++k)s.observed.predictions[k].pc=0x100+k*4;
                cov.sample(s,true);}
            const auto path=dir+"/"+std::to_string(n);std::filesystem::create_directories(path);std::ofstream(path+"/coverage.json")<<cov.json()<<'\n';}return 0;
    }
    Config c;c.lanes=4;std::filesystem::create_directories(dir);Scoreboard b(c,Contract{},7,dir,true);Sample s;s.phase="pre";s.cycle=0;s.stimulus.scenario="synthetic-confidence";
    if(kind=="output-failure") {
        s.expected.write=known(0,"FM01");
        b.sample(s);
        std::filesystem::create_symlink("/dev/full",std::filesystem::path(dir)/"report.json");
        b.final_state(State{});
        try { b.finish({},false,"output-failure"); }
        catch(const std::runtime_error& e) {
            return std::string(e.what())=="report write failed"?0:2;
        }
        return 1;
    }
    // Exact independent values survive unrelated unknown associations.
    if(kind=="unverified"){
        s.expected.valid=known(1,"FM09","I","FQ05:unverified-output-timing (I)");s.actual.valid=false;
        s.expected.mask=known(1,"FM05");s.actual.mask=0;
        s.expected.lanes[0].word=known(0x13,"FM06");s.actual.payload.words[0]=0;
    }else if(kind=="matched"){
        s.expected.valid=known(1,"FM09","I","registered-answer (I)");s.actual.valid=true;
        s.expected.mask=known(1,"FM05");s.actual.mask=1;
        s.expected.lanes[0].word=known(0x13,"FM06");s.actual.payload.words[0]=0;
    }else if(kind=="definitive"){
        s.expected.mask=unknown("FQ04:unknown-association");s.expected.write=known(0,"FM01");s.actual.write=true;
    }else return 2;
    b.sample(s);b.final_state(State{});return b.finish({},false,"synthetic");
}
