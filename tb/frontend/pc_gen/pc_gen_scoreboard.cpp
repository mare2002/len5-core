// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include "pc_gen_scoreboard.hh"
#include "tb_macros.hh"
#include <inttypes.h>
#include <sstream>
#include <stdexcept>

namespace len5::pcgen {
static std::string actual_json(const Outputs& o) {
    return "{\"pc\":" + json_quote(hex64(o.pc)) + ",\"valid\":" + std::to_string(o.valid)
        + ",\"branch_ready\":" + std::to_string(o.branch_ready) + ",\"early_target\":" + json_quote(hex64(o.early_target)) + "}";
}
std::string sample_json(const Sample& s) {
    std::ostringstream r;
    r << "{\"scenario\":" << json_quote(s.stimulus.scenario) << ",\"test_name\":" << json_quote(s.stimulus.test_name)
      << ",\"requirements\":" << json_quote(s.stimulus.requirements) << ",\"campaign\":" << json_quote(name(s.stimulus.campaign))
      << ",\"cycle\":" << s.cycle << ",\"event_time\":" << s.time << ",\"phase\":" << json_quote(s.phase)
      << ",\"epoch\":" << s.epoch << ",\"inputs\":" << inputs_json(s.observed_inputs)
      << ",\"branch_id\":" << s.stimulus.branch_id << ",\"early_id\":" << s.stimulus.early_id
      << ",\"commit_id\":" << s.stimulus.commit_id << ",\"prediction_lane\":" << s.stimulus.prediction_lane << ",\"previous_expected_pc\":" << field_json(s.previous_pc)
      << ",\"branch_cause\":" << json_quote(s.stimulus.branch_cause) << ",\"early_source\":" << json_quote(s.stimulus.early_source)
      << ",\"record_age\":" << s.stimulus.record_age << ",\"malformed\":" << (s.stimulus.malformed?"true":"false")
      << ",\"selected_event\":" << json_quote(name(s.transition.event)) << ",\"next_expected_pc\":" << field_json(s.transition.next_pc)
      << ",\"control_acceptance_known\":" << (s.transition.control_acceptance_known?"true":"false")
      << ",\"control_accepted\":" << (s.transition.control_acceptance_known?(s.transition.control_accepted?"true":"false"):"null")
      << ",\"ordinary_acceptance_known\":" << (s.transition.acceptance_known?"true":"false")
      << ",\"ordinary_accepted\":" << (s.transition.acceptance_known?(s.transition.ordinary_acceptance?"true":"false"):"null")
      << ",\"expected\":" << expected_json(s.expected) << ",\"actual\":" << actual_json(s.actual)
      << ",\"injected\":" << (s.injected ? "true" : "false") << '}';
    return r.str();
}
void Coverage::sample(const Sample& s, bool match) {
    const unsigned ci = static_cast<unsigned>(s.stimulus.campaign);
    const std::string campaign = name(s.stimulus.campaign);
    const std::string prefix = campaign + "/";
    const auto& i = s.observed_inputs;
    ++counters_["V13/" + s.phase];
    ++counters_[prefix + "samples"];
    const std::pair<const char*,const Field*> fields[]={{"pc",&s.expected.pc},{"valid",&s.expected.valid},
        {"branch_ready",&s.expected.branch_ready},{"early_target",&s.expected.early_target}};
    const auto disposition=[](const Field& f) { return f.known?"/checked":f.question.rfind("DC:",0)==0?"/dont_care":"/unknown"; };
    for (const auto& p : fields)
        ++counters_["V15/" + prefix + p.first + disposition(*p.second)];
    if (s.phase == "async" || s.phase == "probe") ++counters_[prefix+"exercised/D"];
    if(s.phase=="pre" || s.phase=="async" || s.phase=="probe")
        ++counters_["V15/"+prefix+"input_state/"+(s.previous_pc.known?"known":"unknown")+"->"+(s.expected.pc.known?"known":"unknown")];
    if (s.phase == "post") {
        if(i.rst_n && i.early) {
            const std::string relation=s.actual.early_target==i.early_base+i.early_offset?"early_arithmetic":
                s.actual.early_target==s.actual.pc?"observed_post_pc":"other";
            ++counters_["Q4/"+prefix+"observation/"+relation+"/X"+std::to_string(i.combination())];
        }
        for(const auto& field:fields) ++counters_["V15/"+prefix+name(s.transition.event)+"/"+field.first+disposition(*field.second)];
        ++counters_["V15/"+prefix+"state/"+(s.previous_pc.known?"known":"unknown")+"->"+(s.expected.pc.known?"known":"unknown")];
        const std::string outcome = s.expected.pc.known && match ? name(s.transition.event) : "unresolved_or_failing";
        if(!campaign_previous_[ci].empty()) ++counters_["V09/"+prefix+campaign_previous_[ci]+"->"+outcome];
        campaign_previous_[ci]=outcome;
        if(previous_reset_[ci] && i.rst_n) ++counters_["V04/"+prefix+"release/"+outcome+"/M="+std::to_string(i.ready)];
        previous_reset_[ci]=!i.rst_n;
        if (s.expected.pc.known && match) {
            const std::string event=name(s.transition.event);
            ++counters_["V03/" + prefix + "checked_outcome/" + event + "/M=" + std::to_string(i.ready)];
            if (!previous_event_.empty()) ++counters_["V09/"+previous_event_+"->"+prefix+event];
            previous_event_=prefix+event;
            const std::vector<std::pair<Event,uint64_t>> targets={{Event::Commit,i.commit_pc},
                {i.taken?Event::TakenRecovery:Event::FallthroughRecovery,i.taken?i.branch_target:i.branch_pc+config_.instruction_bytes},
                {Event::Early,i.early_base+i.early_offset},{Event::Prediction,i.prediction_target}};
            const bool active[]={i.commit,i.recovery(),i.early,i.prediction};
            for(unsigned n=0;n<4;++n) if(active[n] && targets[n].first!=s.transition.event
                && s.transition.event!=Event::Hold && s.transition.event!=Event::Sequential)
                ++counters_["V11/"+prefix+"checked_outcome/"+event+">"+name(targets[n].first)
                    +(targets[n].second==s.actual.pc?"/equal_targets":"/distinct_targets")];
            if(s.transition.event==Event::Commit || s.transition.event==Event::TakenRecovery
                || s.transition.event==Event::FallthroughRecovery || s.transition.event==Event::Early || s.transition.event==Event::Prediction)
                ++counters_["V17/"+prefix+"pass_through/"+event+"/low_bits/"+std::to_string(s.actual.pc%config_.instruction_bytes)];
            ++counters_["V06/"+prefix+event+"/observed_target_lane/"
                +std::to_string((s.actual.pc%config_.bundle_bytes())/config_.instruction_bytes)];
            if(s.transition.event==Event::Sequential || s.transition.event==Event::FallthroughRecovery || s.transition.event==Event::Early) {
                const bool source_known=s.transition.event!=Event::Sequential || s.previous_pc.known;
                const uint64_t source=s.transition.event==Event::Sequential?s.previous_pc.value:
                    s.transition.event==Event::FallthroughRecovery?i.branch_pc:i.early_base;
                if(source_known) {
                    if((source>>32)!=(s.actual.pc>>32)) ++counters_["V12/"+prefix+"arithmetic/"+event+"/32bit_boundary"];
                    if((source>>63)!=(s.actual.pc>>63)) ++counters_["V12/"+prefix+"arithmetic/"+event+"/sign_boundary"];
                    const bool negative=s.transition.event==Event::Early && i.early_offset>UINT64_MAX/2;
                    const bool wrap=negative?source<uint64_t(0)-i.early_offset:s.actual.pc<source;
                    if(wrap) ++counters_["V12/"+prefix+"arithmetic/"+event+"/wrap"];
                }
            }
            if (s.previous_pc.known) {
                const uint64_t old=s.previous_pc.value, target=s.actual.pc;
                const std::string category=target==old?"same_pc":target==config_.boot_pc?"boot":target<old?"backward"
                    : target/config_.bundle_bytes()==old/config_.bundle_bytes()?"same_bundle"
                    : target/config_.bundle_bytes()==old/config_.bundle_bytes()+1?"adjacent":"far";
                ++counters_["V06/"+prefix+event+"/"+category];
                if (target<old) ++counters_["V12/"+prefix+"observed_address_decrease/"+event];
                if ((old>>32)!=(target>>32)) ++counters_["V12/"+prefix+"observed_upper_word_change/"+event];
                if ((old>>63)!=(target>>63)) ++counters_["V12/"+prefix+"observed_sign_region_change/"+event];
            }
        } else {
            ++counters_["V03/"+prefix+"unresolved_or_failing_outcome"];
            previous_event_=prefix+"unresolved_or_failing";
        }
        return;
    }
    if (s.phase != "pre") return;
    // Campaign windows can be separated by hundreds of other-campaign edges.
    // Only adjacent consuming cycles form a consecutive sequence/stall burst.
    if(have_previous_[ci] && s.cycle!=previous_cycle_[ci]+1) {
        if(campaign_stalls_[ci]) ++counters_["V10/"+prefix+"interrupted_stall/"+std::to_string(campaign_stalls_[ci])];
        campaign_stalls_[ci]=0; have_previous_[ci]=false;
        campaign_previous_[ci].clear(); previous_reset_[ci]=false;
    }
    previous_cycle_[ci]=s.cycle;
    const unsigned row = i.combination();
    if (!i.rst_n) ++campaign_resets_[ci][row][i.ready];
    else ++campaign_combinations_[ci][row][i.ready][i.recovery() && i.taken];
    ++counters_[prefix+"cycles"];
    if(s.epoch!=previous_epoch_[ci]) { ++counters_["V16/"+prefix+"epoch_cancellation"]; previous_epoch_[ci]=s.epoch; }
    if(s.stimulus.branch_id || s.stimulus.early_id) ++counters_["V16/"+prefix+"distance/"+
        (s.stimulus.record_age==0?"0":s.stimulus.record_age==1?"1":s.stimulus.record_age<=config_.bundle_instructions?"2..N":">N")];
    if(!(row&4)) ++counters_["V02/"+prefix+"X"+std::to_string(row)+"/M="+std::to_string(i.ready)+"/B="+std::to_string(i.branch_valid)
        +"/mis="+std::to_string(i.mispredict)+"/taken="+std::to_string(i.taken)];
    ++counters_[prefix+"exercised/H"];
    ++counters_[prefix+"exercised/"+(i.recovery()?(i.taken?"R-T":"R-N"):(i.branch_valid?"R-C":"R-I"))];
    if(!i.prediction) ++counters_[prefix+"exercised/P-N"];
    if(!i.early) ++counters_[prefix+"exercised/J-I"];
    if(!i.rst_n) ++counters_[prefix+"exercised/Z"];
    if(have_previous_[ci]) {
        const auto& prev=previous_inputs_[ci];
        if(prev.rst_n && i.rst_n && !prev.ready && !i.ready
            && (prev.prediction!=i.prediction || prev.prediction_target!=i.prediction_target))
            ++counters_["V18/"+prefix+"prediction_changed_during_stall"];
        if(!prev.rst_n && i.rst_n) ++counters_[prefix+"exercised/U"];
        if(!i.early && (prev.early_base!=i.early_base || prev.early_offset!=i.early_offset)) ++counters_["V11/"+prefix+"inactive_early_changed"];
        if(!i.prediction && prev.prediction_target!=i.prediction_target) ++counters_["V11/"+prefix+"inactive_prediction_changed"];
        if(!i.branch_valid && (prev.branch_pc!=i.branch_pc || prev.branch_target!=i.branch_target || prev.mispredict!=i.mispredict || prev.taken!=i.taken)) ++counters_["V11/"+prefix+"invalid_resolution_changed"];
        if(!i.commit && prev.commit_pc!=i.commit_pc) ++counters_["V11/"+prefix+"inactive_commit_changed"];
    }
    previous_inputs_[ci]=i; have_previous_[ci]=true;
    const std::string stage = !i.ready ? (campaign_stalls_[ci]?"inside":"onset") : (campaign_stalls_[ci]?"release":"ready");
    ++counters_["V10/"+prefix+stage+"/"+name(s.transition.event)];
    if(!i.ready) ++campaign_stalls_[ci];
    else if(campaign_stalls_[ci]) {
        const unsigned n=campaign_stalls_[ci];
        ++counters_["V10/"+prefix+"length/"+(n==1?"1":n==2?"2":n<=config_.bundle_instructions?"3..N":n<=32?">N":"long")];
        campaign_stalls_[ci]=0;
    }
    if(i.early && i.early_offset==uint64_t(-1048576)) ++counters_["V08/"+prefix+"min_JAL"];
    if(i.early && i.early_offset==1048572) ++counters_["V08/"+prefix+"max_aligned_JAL"];
    if(i.early && i.early_base && i.early_offset>UINT64_MAX/2 && i.early_base < uint64_t(0)-i.early_offset)
        ++counters_["V12/"+prefix+"early_underflow"];
    const auto boundary=[&](uint64_t a) {
        return a==0?"zero":a==config_.boot_pc?"boot":a>=UINT64_MAX-63?"top":
            a>=UINT64_C(0x7fffffffffffffc0)&&a<=UINT64_C(0x8000000000000040)?"sign_boundary":
            a>=UINT64_C(0xffffffc0)&&a<=UINT64_C(0x100000040)?"32bit_boundary":"other";
    };
    ++counters_["V12/"+prefix+"pc_class/"+boundary(s.actual.pc)];
    if(i.commit) ++counters_["V12/"+prefix+"E_target/"+boundary(i.commit_pc)];
    if(i.recovery()) ++counters_["V12/"+prefix+"R_target/"+boundary(i.taken?i.branch_target:i.branch_pc+config_.instruction_bytes)];
    if(i.early) ++counters_["V12/"+prefix+"J_target/"+boundary(i.early_base+i.early_offset)];
    if(i.prediction) ++counters_["V12/"+prefix+"P_target/"+boundary(i.prediction_target)];
    if(!s.stimulus.branch_cause.empty() && !i.branch_valid) ++counters_["V07/"+prefix+s.stimulus.branch_cause];
    if (!i.rst_n) {
        ++resets_[row][i.ready];
        ++counters_["V14/boot_address/"+hex64(config_.boot_pc)];
        ++counters_["V14/boot_alignment/"+std::to_string(config_.boot_pc%config_.instruction_bytes)];
    }
    else ++combinations_[row][i.ready][i.recovery() && i.taken];
    ++counters_["V01/" + prefix + "X" + std::to_string(row) + "/M=" + std::to_string(i.ready)];
    ++counters_["V02/" + prefix + "B=" + std::to_string(i.branch_valid) + "/mis="
                + std::to_string(i.mispredict) + "/taken=" + std::to_string(i.taken)];
    for (const auto& p : std::vector<std::pair<const char*,bool>>{{"E",i.commit},{"R",i.recovery()},
            {"J",i.early},{"P",i.prediction},{"reset",!i.rst_n},{"ready",i.ready},{"stall",!i.ready}})
        if (p.second) ++counters_[prefix + "exercised/" + p.first];
    ++counters_[prefix + "observed_start_lane/" + std::to_string((s.actual.pc % config_.bundle_bytes()) / config_.instruction_bytes)];
    if (s.previous_pc.known)
        ++counters_["V05/" + prefix + name(s.transition.event) + "/expected_start_lane/"
                    + std::to_string((s.previous_pc.value % config_.bundle_bytes()) / config_.instruction_bytes)];
    if (i.recovery() && !i.taken) ++counters_["V05/"+prefix+"R-N/instruction_lane/" + std::to_string((i.branch_pc % config_.bundle_bytes()) / config_.instruction_bytes)];
    if (i.recovery() && !s.stimulus.branch_cause.empty()) ++counters_["V07/"+prefix+s.stimulus.branch_cause];
    if (i.early && !s.stimulus.early_source.empty()) ++counters_["V08/"+prefix+s.stimulus.early_source];
    if (s.stimulus.branch_id || s.stimulus.early_id) ++counters_["V16/"+prefix+"record_age/"+std::to_string(s.stimulus.record_age)];
    ++counters_["V03/" + prefix + "planned/" + name(s.transition.event) + "/M=" + std::to_string(i.ready)];
    if (i.early) {
        const std::string offset = i.early_base == 0 ? "return_or_zero_base" : i.early_offset == 0 ? "zero"
            : i.early_offset > UINT64_MAX/2 ? "negative" : "positive";
        ++counters_["V08/" + prefix + offset + "/M=" + std::to_string(i.ready) + "/P=" + std::to_string(i.prediction)];
    }
    if (!i.ready) ++stall_length_;
    else if (stall_length_) {
        ++counters_["V10/stall_length/" + std::string(stall_length_ == 1 ? "1" : stall_length_ == 2 ? "2"
            : stall_length_ <= config_.bundle_instructions ? "3..N" : "long")]; stall_length_ = 0;
    }
    ++counters_["actual_qualified_fetches/" + std::to_string(s.actual.valid && i.ready)];
}
bool Coverage::architectural_row(unsigned row) {
    const unsigned controls = unsigned(bool(row&8))+unsigned(bool(row&4))+unsigned(bool(row&2));
    return controls<=1;
}
uint64_t Coverage::combination_count(Campaign c, unsigned row, bool ready, bool taken) const {
    return campaign_combinations_[static_cast<unsigned>(c)][row][ready][(row&4)&&taken];
}
uint64_t Coverage::reset_count(Campaign c, unsigned row, bool ready) const {
    return campaign_resets_[static_cast<unsigned>(c)][row][ready];
}
unsigned Coverage::campaign_holes(Campaign c) const {
    unsigned result=0;
    for(unsigned r=0;r<16;++r) if(c!=Campaign::Architectural || architectural_row(r))
        for(unsigned m=0;m<2;++m) for(unsigned t=0;t<((r&4)?2:1);++t) result+=!combination_count(c,r,m,t);
    return result;
}
unsigned Coverage::matrix_holes() const {
    unsigned holes = 0;
    for (unsigned r=0;r<16;++r) for (unsigned m=0;m<2;++m)
        for (unsigned t=0;t<((r&4)?2:1);++t) holes += !combinations_[r][m][t];
    return holes;
}
unsigned Coverage::reset_holes() const {
    unsigned holes = 0;
    for (unsigned r=0;r<16;++r) for (unsigned m=0;m<2;++m) holes += !resets_[r][m];
    return holes;
}
static void map_json(std::ostream& f, const std::map<std::string,uint64_t>& counters) {
    f << '{'; bool first = true;
    for (const auto& p : counters) { if (!first) f << ','; first = false; f << '\n' << json_quote(p.first) << ':' << p.second; }
    f << '}';
}
std::pair<unsigned,unsigned> Coverage::feature_goals(std::ostream& f, Campaign c) const {
    const std::string p=std::string(name(c))+"/";
    std::vector<std::pair<std::string,std::string>> goals;
    const auto add=[&](std::string key,std::string gate="selected contract; unknown outcomes remain gaps") { goals.emplace_back(key,gate); };
    for(const char* e:{"E","R-T","R-N","R-I","P","P-N","J","J-I","Z","U","H","D","ready","stall"}) add(p+"exercised/"+e,"observable driven input/phase");
    if(c!=Campaign::Architectural) add(p+"exercised/R-C","noncanonical standalone qualification");
    const char* events[]={"reset","commit","R-T","R-N","early","prediction","sequential","hold"};
    for(unsigned e=0;e<8;++e) for(unsigned m=0;m<2;++m) {
        if((e==5 || e==6) && m==0) continue;
        if(e==7 && m==1) continue;
        add("V03/"+p+"checked_outcome/"+events[e]+"/M="+std::to_string(m));
    }
    for(unsigned lane=0;lane<config_.bundle_instructions;++lane) {
        for(const char* e:{"sequential","prediction"}) add("V05/"+p+e+"/expected_start_lane/"+std::to_string(lane));
        add("V05/"+p+"R-N/instruction_lane/"+std::to_string(lane));
        for(const char* e:{"commit","R-T","R-N","early","prediction"}) add("V06/"+p+e+"/observed_target_lane/"+std::to_string(lane));
    }
    for(const char* e:{"commit","R-T","R-N","early","prediction"}) for(const char* category:{"same_pc","boot","backward","same_bundle","adjacent","far"}) {
        if(config_.bundle_instructions==1 && std::string(category)=="same_bundle" && c!=Campaign::Characterization) continue;
        add("V06/"+p+e+"/"+category);
    }
    if(c==Campaign::Architectural) for(const char* cause:{"direction_error","taken_target_error","correct_BPU_only"}) add("V07/"+p+cause,"generated history, not inferred from DUT");
    for(const char* off:{"negative","zero","positive","return_or_zero_base"}) for(unsigned m=0;m<2;++m) for(unsigned prediction=0;prediction<2;++prediction)
        add("V08/"+p+off+"/M="+std::to_string(m)+"/P="+std::to_string(prediction),"offered signed payload; selected early PC and metadata approved D");
    for(const char* length:{"1","2","3..N",">N","long"}) {
        if(config_.bundle_instructions<3 && std::string(length)=="3..N") continue;
        add("V10/"+p+"length/"+length,"completed stall burst; unfinished burst reported separately");
    }
    for(unsigned old=0;old<8;++old) for(unsigned next=0;next<8;++next) {
        // Conservative producer policy: reset discards histories; E cancels
        // younger records; accepted R waits for a backend flush/resume episode.
        if(c==Campaign::Architectural && ((old==0 && next>=1 && next<=4)
            || (old==1 && next>=1 && next<=4) || ((old==2||old==3) && next>=2 && next<=4))) continue;
        add("V09/"+p+events[old]+"->"+events[next]);
    }
    for(const char* changed:{"inactive_early_changed","inactive_prediction_changed","invalid_resolution_changed","inactive_commit_changed"})
        add("V11/"+p+changed,"inactive payload change actually driven");
    for(const char* event:{"commit","R-T","R-N","early"}) for(const char* equal:{"equal_targets","distinct_targets"})
        add("V11/"+p+"checked_outcome/"+event+">prediction/"+equal);
    for(const char* winner:{"reset","commit","R-T","R-N"}) for(const char* loser:{"commit","R-T","R-N","early","prediction"}) {
        const std::string w=winner,l=loser;
        const bool pair=w=="reset" || (w=="commit" && (l=="R-T"||l=="R-N"||l=="early")) || ((w=="R-T"||w=="R-N")&&l=="early");
        if(!pair || (c==Campaign::Architectural && w!="reset")) continue;
        for(const char* equal:{"equal_targets","distinct_targets"}) add("V11/"+p+"checked_outcome/"+w+">"+l+"/"+equal,"contract selection; equal targets do not expose internal priority");
    }
    for(const char* event:{"sequential","R-N","early"}) for(const char* category:{"32bit_boundary","sign_boundary","wrap"})
        add("V12/"+p+"arithmetic/"+event+"/"+category,"matched public arithmetic result; approved bundle and modular contracts");
    for(const char* category:{"zero","boot","top","sign_boundary","32bit_boundary","other"}) {
        if(std::string(category)=="boot" && config_.boot_pc==0) continue;
        add("V12/"+p+"pc_class/"+category,"observed public PC class, no physical-map claim");
    }
    add("V18/"+p+"prediction_changed_during_stall","actually observed changes on adjacent stalled consuming cycles");
    if(c==Campaign::Characterization) for(const char* e:{"commit","R-T","R-N","early","prediction"})
        for(unsigned low=1;low<=3;++low) add("V17/"+p+"pass_through/"+e+"/low_bits/"+std::to_string(low),"Q7 exact public output match; architectural alignment excluded");
    add("V16/"+p+"epoch_cancellation","reset invalidates independent environment epoch");
    if(c==Campaign::Architectural) {
        if(config_.bundle_instructions>=2) add("V16/"+p+"distance/2..N","mature live record");
        add("V16/"+p+"distance/>N","mature live record");
    }
    if(c!=Campaign::Architectural) for(unsigned row=0;row<16;++row) if(!(row&4)) for(unsigned m=0;m<2;++m) for(unsigned raw=0;raw<6;++raw)
        add("V02/"+p+"X"+std::to_string(row)+"/M="+std::to_string(m)+"/B="+std::to_string(raw>=4)+"/mis="+std::to_string(raw<4&&raw>=2)+"/taken="+std::to_string(raw%2),"non-R qualification encodings; architectural producer excludes R-C");
    unsigned hit=0;
    f<<'['; bool first=true;
    for(const auto& goal:goals) {
        if(!first) f<<',';
        first=false;
        const auto found=counters_.find(goal.first);
        hit+=found!=counters_.end() && found->second>0;
        f<<"{\"bin\":"<<json_quote(goal.first)<<",\"count\":"<<(found==counters_.end()?0:found->second)
            <<",\"gate\":"<<json_quote(goal.second)<<'}';
    }
    f<<']';
    return {hit,unsigned(goals.size())};
}
void Coverage::configuration_exclusions(std::ostream& f) const {
    f<<'['; bool first=true;
    const auto exclude=[&](const char* bin,const char* reason) {
        if(!first) f<<',';
        first=false; f<<"{\"bin\":"<<json_quote(bin)<<",\"reason\":"<<json_quote(reason)<<'}';
    };
    if(config_.bundle_instructions==1) {
        exclude("V06/architectural,interface_stress/same_bundle","N=1: distinct instruction-aligned generated addresses cannot share a bundle; characterization includes raw byte targets");
        exclude("V16/architectural/distance/2..N","N=1: minimum instruction maturity is two cycles");
        exclude("V14/non_bundle_aligned_boot","N=1: every instruction-aligned boot address is bundle-aligned");
    }
    if(config_.bundle_instructions<3) exclude("V10/*/length/3..N","N<3: empty completed-stall interval");
    exclude("V05,V06/lanes>=N","lane indices outside selected RTL bundle do not exist");
    f<<']';
}
void Coverage::write(const std::string& path, const std::map<std::string,uint64_t>& requirements,
    const std::map<std::string,uint64_t>& assumptions, const std::map<std::string,uint64_t>& unknowns,
    const std::map<std::string,uint64_t>& dont_cares) const {
    std::ofstream f(path);
    f << "{\"scope\":\"V01-V18 observed functional coverage; contract-dependent, not full sign-off\","
      << "\"matrix_required\":48,\"matrix_holes\":" << matrix_holes()
      << ",\"reset_required\":32,\"reset_holes\":" << reset_holes()
      << ",\"LEN5_MULTIPLE_ISSUES\":"<<config_.bundle_instructions<<",\"bundle_bytes\":"<<config_.bundle_bytes()
      << ",\"configuration_exclusions\":"; configuration_exclusions(f); f<<",\"counters\":";
    map_json(f,counters_); f << ",\"matrix\":[";
    bool first = true;
    for (unsigned r=0;r<16;++r) for (unsigned m=0;m<2;++m) for (unsigned t=0;t<((r&4)?2:1);++t) {
        if (!first) f << ',';
        first = false;
        f << "{\"row\":" << r << ",\"ready\":" << m << ",\"taken\":" << t << ",\"count\":" << combinations_[r][m][t] << '}';
    }
    f << "],\"reset_matrix\":["; first=true;
    for (unsigned r=0;r<16;++r) for (unsigned m=0;m<2;++m) {
        if (!first) f << ',';
        first=false;
        f << "{\"row\":" << r << ",\"ready\":" << m << ",\"count\":" << resets_[r][m] << '}';
    }
    f << "],\"campaigns\":{";
    for(unsigned c=0;c<3;++c) {
        if(c) f<<',';
        const auto campaign=static_cast<Campaign>(c);
        f<<json_quote(name(campaign))<<":{\"matrix_required\":"<<(c==0?20:48)
            <<",\"matrix_holes\":"<<campaign_holes(campaign)<<",\"exclusions\":[";
        bool excluded_first=true;
        if(c==0) for(unsigned r=0;r<16;++r) if(!architectural_row(r)) {
            if(!excluded_first) f<<',';
            excluded_first=false;
            f<<"{\"row\":"<<r<<",\"reason\":\"conditional E/R/J overlap: integrated reachability/cancellation Q2/Q3/Q9; covered by interface stress\"}";
        }
        f<<"],\"qualification_exclusions\":"<<json_quote(c==0?"R-C is BPU-only in current producer; misaligned/stale histories are characterization; consecutive acknowledged R awaits backend flush Q5/Q9":"none at pin-level; characterization is observational, not architectural sign-off")
            <<",\"matrix\":[";
        bool first_bin=true;
        for(unsigned r=0;r<16;++r) for(unsigned m=0;m<2;++m) for(unsigned t=0;t<((r&4)?2:1);++t) {
            if(!first_bin) f<<',';
            first_bin=false;
            f<<"{\"row\":"<<r<<",\"ready\":"<<m<<",\"taken\":"<<t
                <<",\"required\":"<<(c==0&&!architectural_row(r)?"false":"true")<<",\"count\":"<<combination_count(campaign,r,m,t)<<'}';
        }
        f<<"],\"reset_matrix\":[";
        first_bin=true;
        for(unsigned r=0;r<16;++r) for(unsigned m=0;m<2;++m) {
            if(!first_bin) f<<',';
            first_bin=false;
            f<<"{\"row\":"<<r<<",\"ready\":"<<m<<",\"count\":"<<reset_count(campaign,r,m)<<'}';
        }
        f<<"],\"unfinished_stall_length\":"<<campaign_stalls_[c]<<",\"feature_goals\":"; feature_goals(f,campaign); f<<'}';
    }
    f<<"},\"requirement_checks\":"; map_json(f,requirements);
    f<<",\"assumption_checks\":"; map_json(f,assumptions);
    f<<",\"unknown_output_samples\":"; map_json(f,unknowns);
    f<<",\"dont_care_output_samples\":"; map_json(f,dont_cares);
    f<<",\"unresolved_questions\":[\"Q1\",\"Q3\",\"Q4\",\"Q5\",\"Q9\"]";
    f<<",\"specification_status\":"<<specification_status_json()<<"}\n";
    f.close();
    if (!f) throw std::runtime_error("cannot write functional coverage report");
}
Scoreboard::Scoreboard(Config cfg, Contract c, uint64_t seed, const std::string& directory, bool full_journal)
    : config_(cfg), contract_(c), seed_(seed), directory_(directory), journal_(directory + "/samples.jsonl"), full_journal_(full_journal), coverage(cfg) {
    if (!journal_) throw std::runtime_error("cannot open observed-sample journal");
}
void Scoreboard::mismatch(const Sample& s, const char* field, const Field& e, uint64_t actual) {
    ++field_errors_; ++campaign_errors_[static_cast<unsigned>(s.stimulus.campaign)];
    if (s.injected) ++injected_;
    else if (e.assumptions.empty()) ++confirmed_;
    else ++provisional_;
    const std::string category = s.injected ? "injected_checker_failure" : e.assumptions.empty()
        ? "confirmed_dut_mismatch" : "provisional_contract_mismatch";
    const std::string record = "{\"category\":" + json_quote(category) + ",\"field\":" + json_quote(field)
        + ",\"requirement\":" + json_quote(e.requirement) + ",\"evidence\":" + json_quote(e.evidence)
        + ",\"assumptions\":" + json_quote(e.assumptions) + ",\"expected\":" + json_quote(hex64(e.value))
        + ",\"actual\":" + json_quote(hex64(actual)) + ",\"sample\":" + sample_json(s) + "}";
    std::string recent="[";
    for(const auto& h:history_) {
        if(recent.size()>1) recent+=',';
        recent+=sample_json(h);
        if(!full_journal_) journal_<<sample_json(h)<<'\n';
    }
    recent+=']';
    discrepancies_.push_back(record.substr(0,record.size()-1)+",\"history\":"+recent+"}");
    if (field_errors_ > 12) return; // All failures remain in JSON; bound console follow-up.
    TB_ERR("SCB > %s test=%s id=%s req=%s evidence=%s seed=%" PRIu64 " cycle=%" PRIu64 " time=%" PRIu64 " phase=%s epoch=%" PRIu64,
        category.c_str(),s.stimulus.test_name.c_str(),s.stimulus.scenario.c_str(),e.requirement.c_str(),e.evidence.c_str(),
        seed_,s.cycle,s.time,s.phase.c_str(),s.epoch);
    TB_ERR("RSP > field=%s old_pc=%s winner=%s --> actual: %s (expected: %s) assumptions=%s",
        field,s.previous_pc.known?hex64(s.previous_pc.value).c_str():"UNKNOWN",name(s.transition.event),
        hex64(actual).c_str(),hex64(e.value).c_str(),e.assumptions.c_str());
    TB_ERR("REQ > inputs=%s",inputs_json(s.observed_inputs).c_str());
    TB_ERR("SCB > recent observed stimulus history (%zu records), evidence: %s/samples.jsonl",
        history_.size(),directory_.c_str());
    for (const auto& h : history_) TB_ERR("REQ > %s",sample_json(h).c_str());
    if(!replay_command_.empty()) TB_ERR("SCB > Replay: %s",replay_command_.c_str());
}
void Scoreboard::compare(const Sample& s, const char* field, const Field& e, uint64_t actual, bool& failed) {
    if (!e.known) { if(e.question.rfind("DC:",0)==0) ++dont_cares_[e.question]; else ++unknowns_[e.question]; return; }
    ++field_checks_; ++campaign_checks_[static_cast<unsigned>(s.stimulus.campaign)]; ++requirement_checks_[e.requirement + "/" + e.evidence];
    ++campaign_requirement_checks_[std::string(name(s.stimulus.campaign))+"/"+e.requirement+"/"+e.evidence];
    if (!e.assumptions.empty()) ++assumption_checks_[e.assumptions];
    if (e.value != actual) { failed = true; mismatch(s,field,e,actual); }
}
void Scoreboard::sample(const Sample& s) {
    ++sampled_records_;
    if(s.phase=="pre") {
        pre_cycle_=s.cycle;
        pre_pc_matches_=s.expected.pc.known && s.expected.pc.value==s.actual.pc;
    }
    const uint64_t prior_checks = field_checks_;
    bool failed = false;
    compare(s,"pc_o",s.expected.pc,s.actual.pc,failed);
    compare(s,"valid_o",s.expected.valid,s.actual.valid,failed);
    compare(s,"bu_ready_o",s.expected.branch_ready,s.actual.branch_ready,failed);
    compare(s,"early_jump_target_o",s.expected.early_target,s.actual.early_target,failed);
    // Additional C9 relational diagnosis: a
    // distinct current prediction must not displace the older early correction.
    const auto& i = s.observed_inputs;
    if (s.phase == "post" && i.rst_n && i.early && i.prediction && !i.commit && !i.recovery()
        && s.previous_pc.known && i.prediction_target != s.previous_pc.value
        && i.prediction_target != i.early_base + i.early_offset) {
        // Earlier provisional state discrepancies cannot prove which old PC
        // was held. Keep exact PC comparisons, but qualify this additional
        // definitive relation by a checked, matched pre-edge context.
        if(pre_cycle_==s.cycle && pre_pc_matches_) {
            Field rule{1,true,"C9","D",{}, {}};
            compare(s,"early_priority_over_current_prediction",rule,s.actual.pc != i.prediction_target,failed);
        } else ++unknowns_["C9:prior-PC-context-unverified"];
    }
    if (field_checks_ > prior_checks) ++transactions_;
    if (failed) ++errors_;
    ++scenarios_[s.stimulus.scenario]; ++campaigns_[name(s.stimulus.campaign)];
    if(s.phase=="pre") ++pre_edge_records_;
    if(s.phase=="post") { ++cycles_; ++campaign_cycles_[static_cast<unsigned>(s.stimulus.campaign)]; }
    if(s.phase=="pre" || s.phase=="probe" || s.phase=="async") {
        // Stable FNV-1a over numerical stimulus/config-independent metadata.
        const auto& i=s.observed_inputs;
        const uint64_t values[]={s.cycle,s.time,s.epoch,s.phase=="pre"?0u:s.phase=="probe"?1u:2u,uint64_t(s.stimulus.campaign),i.rst_n,i.commit,i.branch_valid,i.mispredict,i.taken,
            i.prediction,i.ready,i.early,i.commit_pc,i.branch_pc,i.branch_target,i.prediction_target,i.early_base,i.early_offset,
            s.stimulus.branch_id,s.stimulus.early_id,s.stimulus.commit_id,uint64_t(s.stimulus.prediction_lane),s.stimulus.malformed};
        for(uint64_t v:values) for(unsigned byte=0;byte<8;++byte) { stimulus_digest_^=(v>>(byte*8))&255; stimulus_digest_*=UINT64_C(1099511628211); }
    }
    if(full_journal_ || failed || logger.getLogLvl()>=LOG_FULL) {
        const auto record=sample_json(s);
        journal_<<record<<'\n';
        if (!journal_) throw std::runtime_error("cannot write observed-sample journal");
        TB_LOG(LOG_FULL,"RSP > %s",record.c_str());
    }
    coverage.sample(s,!failed);
    if(s.phase=="post" && s.stimulus.campaign==Campaign::Characterization) {
        const std::string key=s.stimulus.scenario+"/X"+std::to_string(i.combination())+"/M="+std::to_string(i.ready)
            +"/reset="+std::to_string(!i.rst_n)+"/known="+std::to_string(s.expected.pc.known);
        if(!observations_.count(key)) observations_.emplace(key,s);
    }
    history_.push_back(s); if(history_.size()>8) history_.pop_front();
    const auto transaction_level=random_metadata_=="null"?LOG_MEDIUM:LOG_HIGH;
    if (logger.getLogLvl()>=transaction_level && s.phase == "post" && !failed && field_checks_ > prior_checks && s.expected.pc.known)
        TB_SUCCESS(transaction_level,"RSP > id=%s cycle=%" PRIu64 " phase=post winner=%s --> pc: %s (expected: %s)",
            s.stimulus.scenario.c_str(),s.cycle,name(s.transition.event),hex64(s.actual.pc).c_str(),
            s.expected.pc.known?hex64(s.expected.pc.value).c_str():"UNKNOWN; characterized");
    else if (logger.getLogLvl()>=transaction_level && s.phase == "post" && !s.expected.pc.known)
        TB_LOG(transaction_level,"RSP > id=%s cycle=%" PRIu64 " phase=post pc=%s UNCHECKED (%s)",
            s.stimulus.scenario.c_str(),s.cycle,hex64(s.actual.pc).c_str(),s.expected.pc.question.c_str());
}
void Scoreboard::random_run(const std::string& metadata, const std::string& replay_command) {
    random_metadata_=metadata; replay_command_=replay_command;
}
void Scoreboard::problem(const std::string& kind, const std::string& reason) {
    if (kind == "environment_error") ++environment_errors_; else ++framework_errors_;
    discrepancies_.push_back("{\"category\":" + json_quote(kind) + ",\"reason\":" + json_quote(reason) + "}");
    TB_ERR("SCB > %s: %s",kind.c_str(),reason.c_str());
}
int Scoreboard::finish(const std::string& reason, bool complete_suite, const std::string& selection) {
    journal_.close();
    if (!journal_) throw std::runtime_error("cannot write observed-sample journal");
    const bool holes = complete_suite && (coverage.matrix_holes() || coverage.reset_holes() || scenarios_.size()!=22);
    const bool incomplete = !reason.empty() || !field_checks_ || holes;
    const int result = (environment_errors_ || framework_errors_) ? 2 : field_errors_ ? 1 : incomplete ? 3 : 0;
    const std::string final_reason = !reason.empty() ? reason : !field_checks_ ? "no meaningful comparisons were performed"
        : holes ? "required directed coverage is incomplete" : field_errors_ ? "output discrepancies; inspect requirement provenance" : "";
    coverage.write(directory_ + "/coverage.json",campaign_requirement_checks_,assumption_checks_,unknowns_,dont_cares_);
    std::ofstream observations(directory_+"/characterization.jsonl");
    for(const auto& p:observations_) observations<<sample_json(p.second)<<'\n';
    observations.close();
    if(!observations) throw std::runtime_error("cannot write characterization observations");
    std::ofstream f(directory_ + "/report.json");
    f << "{\"status\":" << json_quote(result==0?"passed":result==1?"failed":result==2?"invalid":"incomplete")
      << ",\"reason\":" << json_quote(final_reason)
      << ",\"exit_status\":" << result << ",\"full_contract_signoff\":false,\"complete_directed_suite\":"
      << (complete_suite && scenarios_.size()==22 && reason.empty()?"true":"false")
      << ",\"selection\":" << json_quote(selection) << ",\"seed\":" << seed_
      << ",\"timestamp_unit\":\"VerilatedContext tick; clock-stopped probes may add ticks\",\"cycle_definition\":\"zero-based consuming rising edge, including reset\""
      << ",\"config\":{\"boot_pc\":" << json_quote(hex64(config_.boot_pc)) << ",\"xlen\":" << config_.xlen
      << ",\"instruction_bytes\":" << config_.instruction_bytes << ",\"bundle_instructions\":" << config_.bundle_instructions
      << ",\"LEN5_MULTIPLE_ISSUES\":"<<config_.bundle_instructions<<",\"bundle_bytes\":"<<config_.bundle_bytes()
      << ",\"issue_bits\":"<<issue_bits_<<",\"source\":"<<json_quote(config_source_)<<",\"fingerprint\":"<<json_quote(config_fingerprint_)<<'}'
      << ",\"cycles_executed\":" << cycles_ << ",\"stimulus_digest\":" << json_quote(hex64(stimulus_digest_))
      << ",\"sampled_records\":"<<sampled_records_<<",\"pre_edge_records\":"<<pre_edge_records_
      << ",\"journal_mode\":" << json_quote(full_journal_?"full":"failures")
      << ",\"random_configuration\":" << random_metadata_ << ",\"replay_command\":" << json_quote(replay_command_)
      << ",\"transactions\":" << transactions_ << ",\"errors\":" << errors_ << ",\"field_checks\":" << field_checks_
      << ",\"field_errors\":" << field_errors_ << ",\"confirmed_mismatches\":" << confirmed_
      << ",\"provisional_mismatches\":" << provisional_ << ",\"injected_failures\":" << injected_
      << ",\"environment_errors\":" << environment_errors_ << ",\"framework_errors\":" << framework_errors_;
    f << ",\"assumptions\":["; bool first=true;
    for (const auto& a : contract_.assumptions()) { if (!first) f<<','; first=false; f<<json_quote(a); } f<<']';
    f << ",\"unresolved_questions\":[\"Q1\",\"Q3\",\"Q4\",\"Q5\",\"Q9\"]";
    f << ",\"specification_status\":" << specification_status_json();
    f << ",\"characterization_observations\":"<<observations_.size();
    f << ",\"campaign_requirement_checks\":"; map_json(f,campaign_requirement_checks_);
    f << ",\"requirement_checks\":"; map_json(f,requirement_checks_);
    f << ",\"assumption_checks\":"; map_json(f,assumption_checks_);
    f << ",\"unknown_output_samples\":"; map_json(f,unknowns_);
    f << ",\"dont_care_output_samples\":"; map_json(f,dont_cares_);
    f << ",\"scenario_samples\":"; map_json(f,scenarios_);
    f << ",\"campaign_samples\":"; map_json(f,campaigns_);
    f << ",\"discrepancies\":["; first=true;
    for (const auto& d : discrepancies_) { if (!first) f<<','; first=false; f<<'\n'<<d; } f << "]}\n";
    f.close();
    if (!f) throw std::runtime_error("cannot write verification report");
    for(unsigned c=0;c<3;++c) if(campaign_cycles_[c]) {
        const auto campaign=static_cast<Campaign>(c);
        std::ostringstream unused;
        const auto goals=coverage.feature_goals(unused,campaign);
        TB_LOG(LOG_LOW,"SCB > campaign=%s cycles=%" PRIu64 " comparisons=%" PRIu64 " mismatches=%" PRIu64 " matrix_gaps=%u feature_gaps=%u/%u (coverage.json)",
            name(campaign),campaign_cycles_[c],campaign_checks_[c],campaign_errors_[c],coverage.campaign_holes(campaign),goals.second-goals.first,goals.second);
    }
    if (result) TB_ERR("TEST FAILED > errors: %" PRIu64 "/%" PRIu64,errors_,transactions_);
    else TB_SUCCESS(LOG_LOW,"TEST SUCCEEDED > errors: %" PRIu64 "/%" PRIu64,errors_,transactions_);
    TB_LOG(LOG_LOW,"SCB > checks=%" PRIu64 " field_errors=%" PRIu64 " matrix_holes=%u reset_holes=%u report=%s/report.json (partial contract)",
        field_checks_,field_errors_,coverage.matrix_holes(),coverage.reset_holes(),directory_.c_str());
    if(result) TB_ERR("Test failed > pc_gen %s; exit_status=%d",selection.c_str(),result);
    else TB_SUCCESS(LOG_LOW,"Test successfully passed > pc_gen %s",selection.c_str());
    return result;
}
} // namespace len5::pcgen
