#!/bin/bash
# ================== batch command generator ==================
# Usage:
#   bash test.sh                                    # default: all settings, theta=0.2/0.5/0.8
#   bash test.sh -t "0.01"                          # a single theta
#   bash test.sh -t "0.01 0.1 0.2"                 # several thetas
#   bash test.sh -s bBnC-I+E+L          # a single setting
#   bash test.sh -t "0.01" -s bBnC-I+E+L -n Test_Theta0.01 -b 1
#   bash test.sh -t "0.01" -pmed                    # pmed mode
#   bash test.sh -t "0.2 0.5 0.8" --no-colocation   # NoCoLoc variant (y_i <= 1)
#   bash test.sh -t "0.2 0.5 0.8" --all-colocation  # MPCLP and NoCoLoc in one directory
#   bash test.sh -t "0.2 0.5 0.8" -s bBnC-I+E+L -o results/mpclp  # explicit output directory
#   bash test.sh -r "1 2" -R "20 20"                 # several (r,R) pairs, paired by index
#
# Options:
#   -t "0.2 0.5 ..."    theta values (default: "0.2 0.5 0.8")
#   -r "5 10 ..."       r values, paired with -R by index (default: "5 10")
#   -R "20 25 ..."      R values, paired with -r by index (default: "20 25")
#   --instances "..."   pmed instance ids (default: 1..40)
#   -s <setting>         only these settings, comma separated
#   -n <name>            suffix of the result directory (default: generated)
#   -o <dir>             exact output directory (overrides results/<date>_<suffix>)
#   -b 0|1               bsub submission: 0=only write cmd.sh (default), 1=submit
#   -T <sec>             timelimit (default: 3600)
#   -P <prob_func>       coverage probability function: linear, facility_mixture, logit_slow, logit_mid, logit_fast
#   --mixture-low-shares "<p1 p2 ...>"  low/high facility shares, e.g. "0.8 0.5 0.2"
#   --mixture-seeds "<s1 s2 ...>"       random seeds for facility mixture assignment (default: 1)
#   -N <n>               number of Slurm array bundles (default: 10)
#   tasks.jsonl           always written as research-task-v1; the execution backend binds the output paths
#   -c                   include the Bin mode
#   --bin-only           only the Bin mode (no Int settings)
#   -pmed                pmed comparison mode
#   --colocation         standard MPCLP (colocation=1, co-location allowed)
#   --no-colocation      NoCoLoc variant (colocation=0, y_i <= 1, no y variables)
#   --all-colocation     test colocation=1 and colocation=0 (one directory)
#   --kmed               include the pMP (pure K-median) comparison
#   --kmed-only          only the pMP (K-median) tasks, skip the main loop
#   -l                   list the available settings and exit
#   -h                   show this help
#
# Notes:
#   This script is the site-specific batch generator: by default (-b 0) it only
#   writes <output directory>/cmd.sh and tasks.jsonl, submits nothing and leaves
#   the git state alone; only an explicit -b 1 submits through bsub, and the
#   LSF/research-os parameters of that submission are filled in per site.
#   The recipe driven entry point is scripts/experiments/generate_test_commands.sh
#   (it reads the *.json files next to it); both only generate commands, pick
#   whichever fits.
# =================================================

set -e

script_dir=$(cd $(dirname $0)/ && pwd)
PWD=$(cd $script_dir/../.. && pwd)  # repo root
date=$(date +%Y-%m-%d)

# --- defaults ---
THETAS="0.2 0.5 0.8"
R_VALS="5 10"
R_BIG_VALS="20 25"
INSTANCES=""
SUFFIX=""
SETTINGS=""         # empty = all settings
IS_BSUB=0
TIME_LIMIT=3600
NODES=10
INCLUDE_BIN=0
BIN_ONLY=0
PMED_MODE=0
COLOCATION=""
COLOC_LABEL=""
ALL_COLOCATION=0
KMED_MODE=0
KMED_ONLY=0
OUTPUT_DIR=""
PROB_FUNCS="linear"
MIXTURE_LOW_SHARES="0.8"
MIXTURE_LOW_MIN=0.001
MIXTURE_LOW_MAX=0.01
MIXTURE_HIGH_MIN=0.9
MIXTURE_HIGH_MAX=0.99
MIXTURE_SEEDS="1"

# --- parse the arguments ---
while [[ $# -gt 0 ]]; do
   case $1 in
      -t) THETAS="$2"; shift 2 ;;
      -r) R_VALS="$2"; shift 2 ;;
      -R) R_BIG_VALS="$2"; shift 2 ;;
      --instances) INSTANCES="$2"; shift 2 ;;
      -s) SETTINGS="$2"; shift 2 ;;
      -n) SUFFIX="$2"; shift 2 ;;
      -b) IS_BSUB="$2"; shift 2 ;;
      -T) TIME_LIMIT="$2"; shift 2 ;;
      -P|--prob-func) PROB_FUNCS="$2"; shift 2 ;;
      --mixture-low-shares) MIXTURE_LOW_SHARES="$2"; shift 2 ;;
      --mixture-low-min) MIXTURE_LOW_MIN="$2"; shift 2 ;;
      --mixture-low-max) MIXTURE_LOW_MAX="$2"; shift 2 ;;
      --mixture-high-min) MIXTURE_HIGH_MIN="$2"; shift 2 ;;
      --mixture-high-max) MIXTURE_HIGH_MAX="$2"; shift 2 ;;
      --mixture-seeds) MIXTURE_SEEDS="$2"; shift 2 ;;
      -N) NODES="$2"; shift 2 ;;
      -c) INCLUDE_BIN=1; shift ;;
      --bin-only) BIN_ONLY=1; INCLUDE_BIN=1; shift ;;
      -pmed) PMED_MODE=1; shift ;;
      --colocation) COLOCATION="colocation=1"; COLOC_LABEL="ColocOn"; shift ;;
	      --no-colocation) COLOCATION="colocation=0"; COLOC_LABEL="NoCoLoc"; shift ;;
	      --all-colocation) ALL_COLOCATION=1; shift ;;
      --kmed) KMED_MODE=1; shift ;;
      --kmed-only) KMED_ONLY=1; KMED_MODE=1; shift ;;
      -o) OUTPUT_DIR="$2"; shift 2 ;;
      -l) LIST_SETTINGS=1; shift ;;
      -h|--help)
         # Print the whole leading comment block, so the notes below the option
         # list (including -b 0) reach whoever asks for help.
         awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
         exit 0 ;;
      *) echo "unknown argument: $1"; exit 1 ;;
   esac
done

# --- list the settings ---
if [[ $LIST_SETTINGS -eq 1 ]]; then
   echo "available settings:"
   echo "  bBnC-I              — no strengthening, no VI"
   echo "  bBnC-I+L            — no strengthening, with VI"
   echo "  bBnC-I+E            — with strengthening, no VI"
   echo "  bBnC-I+E+L — the full setting (recommended)"
   echo ""
   echo "Several settings can be given comma separated, e.g. -s bBnC-I,bBnC-I+E+L"
   exit 0
fi

# --- result directory name ---
if [[ -n "$OUTPUT_DIR" ]]; then
   # exact output path (submit_all.sh passes it with -o)
   [[ "$OUTPUT_DIR" = /* ]] && dir_result="$OUTPUT_DIR" || dir_result="${PWD}/${OUTPUT_DIR}"
else
   if [[ -z "$SUFFIX" ]]; then
      th_first=$(echo $THETAS | awk '{print $1}')
      th_last=$(echo $THETAS | awk '{print $NF}')
      if [[ "$THETAS" == "0.2 0.5 0.8" ]]; then
         SUFFIX="Testall"
      elif [[ $(echo $THETAS | wc -w) -eq 1 ]]; then
         SUFFIX="Test_Theta${th_first}"
      else
         SUFFIX="Test_Theta${th_first}_${th_last}"
      fi
      $PMED_MODE -eq 1 && SUFFIX="${SUFFIX}_Pmed"
   fi
   dir_result="${PWD}/results/${date}_${SUFFIX}"
fi

if [[ ! -d "$dir_result" ]]; then
   mkdir -p "$dir_result"
fi

# The result directory is only a record; the script never commits to git.
gitversion=$(git rev-list --max-count=1 HEAD 2>/dev/null || echo "unknown")
gitbranch=$(git symbolic-ref --short -q HEAD 2>/dev/null || echo "unknown")

read -ra arr_r <<< "$R_VALS"
read -ra arr_R <<< "$R_BIG_VALS"
if [[ ${#arr_r[@]} -ne ${#arr_R[@]} ]]; then
   echo "ERROR: -r and -R must contain the same number of values." >&2
   exit 1
fi
if [[ -z "$INSTANCES" ]]; then
   INSTANCE_LIST=$(seq 1 1 40)
else
   INSTANCE_LIST="$INSTANCES"
fi

# --- setting definitions ---
declare -A arr_cmd=()
if [[ -n "$SETTINGS" ]]; then
   IFS=',' read -ra slist <<< "$SETTINGS"
   for s in "${slist[@]}"; do
      s=$(echo $s | xargs)   # trim
      case $s in
         bBnC-I)      arr_cmd["$s"]="methods=bBnC-I" ;;
         bBnC-I+E)    arr_cmd["$s"]="methods=bBnC-I+E" ;;
         bBnC-I+L)    arr_cmd["$s"]="methods=bBnC-I+L" ;;
         bBnC-I+E+L)  arr_cmd["$s"]="methods=bBnC-I+E+L" ;;
         *) echo "unknown setting: $s (use -l for the list)"; exit 1 ;;
      esac
   done
else
   # all of them by default
   arr_cmd["bBnC-I"]="methods=bBnC-I"
   arr_cmd["bBnC-I+L"]="methods=bBnC-I+L"
   arr_cmd["bBnC-I+E"]="methods=bBnC-I+E"
   arr_cmd["bBnC-I+E+L"]="methods=bBnC-I+E+L"
fi

# --- the Test function ---
is_facility_mixture() {
   local prob_func="$1"
   [[ "$prob_func" == "facility_mixture" || "$prob_func" == "facility_mix" || "$prob_func" == "low_high" ]]
}

low_high_label() {
   awk -v low="$1" 'BEGIN { l = int(low * 100 + 0.5); h = 100 - l; printf "lh%02d%02d", l, h }'
}

mixture_low_share_list_for() {
   local prob_func="$1"
   if is_facility_mixture "$prob_func"; then
      echo "$MIXTURE_LOW_SHARES"
   else
      echo "__none__"
   fi
}

mixture_seed_list_for() {
   local prob_func="$1"
   if is_facility_mixture "$prob_func"; then
      echo "$MIXTURE_SEEDS"
   else
      echo "__none__"
   fi
}

append_task() {
   local task_id=$1
   local command=$2
   local stdout_q stderr_q
   printf -v stdout_q '%q' "${dir_result}/${task_id}.out"
   printf -v stderr_q '%q' "${dir_result}/${task_id}.err"
   printf '%s\t%s\n' "$task_id" "$command" >> "$task_records"
   # The generator creates dir_result before writing cmd.sh. Each task owns
   # explicit stdout/stderr paths but must not perform directory management.
   printf '%s > %s 2> %s\n' \
      "$command" "$stdout_q" "$stderr_q" >> "$fn_cmd"
}

Test() {
   local Setting_Name=$1
   local Setting_CMD=$2
   local timelimit=$3
   local mode=${4:-Int}

   fn_cmd=${dir_result}/cmd.sh
   for val_prob in $PROB_FUNCS; do
      local prob_label
      prob_label=$(echo "$val_prob" | sed 's/logit_//')
      for ((indr = 0; indr < ${#arr_r[@]}; indr++)); do
         for val_theta in $THETAS; do
            val_r=${arr_r[indr]}
            val_R=${arr_R[indr]}
            for low_share in $(mixture_low_share_list_for "$val_prob"); do
               for mix_seed in $(mixture_seed_list_for "$val_prob"); do
                  for i in $INSTANCE_LIST; do
                     fn_data=data/pmed${i}.txt
                     jobname="mgclp${i}-${val_r}-${val_R}-${val_theta}-${mode}"

                     cmd="julia src/mgclp.jl fn=${fn_data} theta=${val_theta} r=${val_r} R=${val_R}"
                     cmd="${cmd} prob_func=${val_prob}"
                     if [[ "$low_share" != "__none__" ]]; then
                        lh_label=$(low_high_label "$low_share")
                        cmd="${cmd} mixture_low_share=${low_share}"
                        cmd="${cmd} mixture_low_min=${MIXTURE_LOW_MIN} mixture_low_max=${MIXTURE_LOW_MAX}"
                        cmd="${cmd} mixture_high_min=${MIXTURE_HIGH_MIN} mixture_high_max=${MIXTURE_HIGH_MAX}"
                        cmd="${cmd} mixture_seed=${mix_seed}"
                        jobname="${jobname}-${timelimit}-${prob_label}-${lh_label}-seed${mix_seed}"
                     fi
                     # cutF comes with the methods preset, so it is not passed here
                     cmd="${cmd} init=1 pre=1 mode=${mode} cutM=1 cutP=1 cutC=1"
                     cmd="${cmd} msg=default timelimit=${timelimit} EPS=1e-3 is_Euclidean=0 node_space=5"
                     cmd="${cmd} which_first=both"
                     [[ -n "$COLOCATION" ]] && cmd="${cmd} ${COLOCATION}"
                     [[ -n "$Setting_CMD" ]] && cmd="${cmd} ${Setting_CMD}"

                     if [[ -n "$COLOC_LABEL" ]]; then
                        jobname="${jobname}-${COLOC_LABEL}"
                     fi
                     if [[ "$mode" == "Int" ]]; then
                        jobname="${jobname}+${Setting_Name}"
                     fi

                     if ((IS_BSUB == 1)); then
                        bsub -J ${jobname} -q batch -R "span[ptile=2]" -n 2 \
                           -e "${dir_result}/${jobname}.err" -o "${dir_result}/${jobname}.out" "${cmd}"
                     fi
                     append_task "$jobname" "$cmd"
                  done
               done
            done
         done
      done
   done
}

# --- write cmd.sh ---
fn_cmd=${dir_result}/cmd.sh
task_records=${dir_result}/.tasks.tsv.tmp
: > "$fn_cmd"
: > "$task_records"
echo "# git branch: ${gitbranch}, git version: ${gitversion}" >> "$fn_cmd"

if [[ $KMED_ONLY -eq 1 ]]; then
   # K-median only: write the pMP tasks and skip the main loop
   for val_prob in $PROB_FUNCS; do
      prob_label=$(echo "$val_prob" | sed 's/logit_//')
      for ((indr = 0; indr < ${#arr_r[@]}; indr++)); do
         val_r=${arr_r[indr]}; val_R=${arr_R[indr]}
         for low_share in $(mixture_low_share_list_for "$val_prob"); do
            for mix_seed in $(mixture_seed_list_for "$val_prob"); do
               for i in $INSTANCE_LIST; do
                  fn_data=data/pmed${i}.txt
                  jobname="mgclp${i}-${val_r}-${val_R}-1-pMP"
                  cmd="julia src/mgclp.jl fn=${fn_data} theta=1 r=${val_r} R=${val_R}"
                  cmd="${cmd} prob_func=${val_prob}"
                  if [[ "$low_share" != "__none__" ]]; then
                     lh_label=$(low_high_label "$low_share")
                     cmd="${cmd} mixture_low_share=${low_share}"
                     cmd="${cmd} mixture_low_min=${MIXTURE_LOW_MIN} mixture_low_max=${MIXTURE_LOW_MAX}"
                     cmd="${cmd} mixture_high_min=${MIXTURE_HIGH_MIN} mixture_high_max=${MIXTURE_HIGH_MAX}"
                     cmd="${cmd} mixture_seed=${mix_seed}"
                     jobname="mgclp${i}-${val_r}-${val_R}-1-theta1-${prob_label}-${TIME_LIMIT}-${lh_label}-seed${mix_seed}"
                  fi
                  cmd="${cmd} methods=bBnC-I+E+L cutM=1 cutP=1 cutC=1 pre=1"
                  cmd="${cmd} timelimit=${TIME_LIMIT} EPS=1e-3 node_space=5 pmed=1"
                  append_task "$jobname" "$cmd"
               done
            done
         done
      done
   done
elif [[ $PMED_MODE -eq 1 ]]; then
   # Pmed mode: the Bin comparison only
   for timelimit in $TIME_LIMIT; do
      Test "BnC-B" "methods=BnC-B" $timelimit "Bin"
   done
else
   # Build colocation modes
   if [[ $ALL_COLOCATION -eq 1 ]]; then
      COLOC_MODES=("colocation=1|ColocOn" "colocation=0|NoCoLoc")
   else
      COLOC_MODES=("${COLOCATION}|${COLOC_LABEL}")
   fi

   for coloc_entry in "${COLOC_MODES[@]}"; do
      COLOCATION="${coloc_entry%%|*}"
      COLOC_LABEL="${coloc_entry#*|}"
      [[ "$COLOC_LABEL" == "$coloc_entry" ]] && COLOC_LABEL=""

      for timelimit in $TIME_LIMIT; do
	         if [[ $BIN_ONLY -eq 0 ]]; then
         for setting_name in "${!arr_cmd[@]}"; do
            echo "=== ${setting_name} ==="
            Test "${setting_name}" "${arr_cmd[${setting_name}]}" ${timelimit} "Int"
         done
	         fi
         if [[ $INCLUDE_BIN -eq 1 ]]; then
            Test "BnC-B" "methods=BnC-B" ${timelimit} "Bin"
         fi
      done
   done

   # K-median comparison (pMP), appended after the main loop
   if [[ $KMED_MODE -eq 1 ]]; then
      for val_prob in $PROB_FUNCS; do
         prob_label=$(echo "$val_prob" | sed 's/logit_//')
         for ((indr = 0; indr < ${#arr_r[@]}; indr++)); do
            val_r=${arr_r[indr]}; val_R=${arr_R[indr]}
            for low_share in $(mixture_low_share_list_for "$val_prob"); do
               for mix_seed in $(mixture_seed_list_for "$val_prob"); do
                  for i in $INSTANCE_LIST; do
                     fn_data=data/pmed${i}.txt
                     jobname="mgclp${i}-${val_r}-${val_R}-1-pMP"
                     cmd="julia src/mgclp.jl fn=${fn_data} theta=1 r=${val_r} R=${val_R}"
                     cmd="${cmd} prob_func=${val_prob}"
                     if [[ "$low_share" != "__none__" ]]; then
                        lh_label=$(low_high_label "$low_share")
                        cmd="${cmd} mixture_low_share=${low_share}"
                        cmd="${cmd} mixture_low_min=${MIXTURE_LOW_MIN} mixture_low_max=${MIXTURE_LOW_MAX}"
                        cmd="${cmd} mixture_high_min=${MIXTURE_HIGH_MIN} mixture_high_max=${MIXTURE_HIGH_MAX}"
                        cmd="${cmd} mixture_seed=${mix_seed}"
                        jobname="mgclp${i}-${val_r}-${val_R}-1-theta1-${prob_label}-${TIME_LIMIT}-${lh_label}-seed${mix_seed}"
                     fi
                     cmd="${cmd} methods=bBnC-I+E+L cutM=1 cutP=1 cutC=1 pre=1"
                     cmd="${cmd} timelimit=${TIME_LIMIT} EPS=1e-3 node_space=5 pmed=1"
                     append_task "$jobname" "$cmd"
                  done
               done
            done
         done
      done
   fi
fi

tasks_file=${dir_result}/tasks.jsonl
python3 "${PWD}/scripts/statistics/lib/mpclp/task_jsonl.py" \
   "$task_records" "$tasks_file" \
   --time-limit-seconds "$(( TIME_LIMIT + 300 ))"
rm -f "$task_records"

# --- summary ---
job_count=$(grep -c "julia" "${dir_result}/cmd.sh" 2>/dev/null || echo 0)
echo ""
echo "============================================"
echo "dir_result: $dir_result"
echo "theta:      $THETAS"
echo "r:          $R_VALS"
echo "R:          $R_BIG_VALS"
echo "instances:  $INSTANCE_LIST"
echo "prob_func:  $PROB_FUNCS"
echo "mixture_low_shares: $MIXTURE_LOW_SHARES"
echo "mixture_seeds: $MIXTURE_SEEDS"
if [[ $KMED_ONLY -eq 1 ]]; then
   echo "settings:   pMP (K-median only)"
elif [[ $BIN_ONLY -eq 1 ]]; then
   echo "settings:   BnC-B"
else
   echo "settings:   ${!arr_cmd[@]}"
   [[ $INCLUDE_BIN -eq 1 ]] && echo "            + BnC-B"
fi
echo "tasks:      $job_count"
echo "cmd.sh:     ${dir_result}/cmd.sh"
echo "tasks.jsonl:${tasks_file}"
echo "============================================"

# --- Slurm submit ---
fn_submit=${PWD}/tmp/submit_jobs_$(basename "$dir_result").sh
fn_submit_runhub=${PWD}/tmp/submit_and_register_$(basename "$dir_result").sh
mkdir -p "${PWD}/tmp"

bundle_count=${NODES}
internal_parallelism=${SLURM_INTERNAL_PARALLELISM:-16}
global_parallelism=$(( bundle_count * internal_parallelism ))
cmd_per_wave=$(( (job_count + global_parallelism - 1) / global_parallelism ))
[[ $cmd_per_wave -lt 1 ]] && cmd_per_wave=1
command_timeout=$(( TIME_LIMIT + 300 ))
# One extra hour of buffer for scheduling delay and trailing tasks; queue time is not counted.
total_hours=$(( cmd_per_wave * command_timeout / 3600 + 1 ))
[[ $total_hours -lt 1 ]] && total_hours=1
walltime_seconds=$(( total_hours * 3600 ))
slurm_time="${total_hours}:00:00"
instance_list_inline=$(echo "$INSTANCE_LIST" | tr '\n' ' ' | xargs)
runhub_notes="${job_count} commands; theta=${THETAS}; r=${R_VALS}; R=${R_BIG_VALS}; instances=${instance_list_inline}; prob_func=${PROB_FUNCS}; mixture_low_shares=${MIXTURE_LOW_SHARES}; settings="
if [[ $KMED_ONLY -eq 1 ]]; then
   runhub_notes="${runhub_notes}pMP (K-median only)"
elif [[ $BIN_ONLY -eq 1 ]]; then
   runhub_notes="${runhub_notes}Bin"
else
   runhub_notes="${runhub_notes}${!arr_cmd[@]}"
   [[ $INCLUDE_BIN -eq 1 ]] && runhub_notes="${runhub_notes} + BnC-B"
fi

if [[ ! "$bundle_count" =~ ^[0-9]+$ ]] || [[ $bundle_count -lt 1 ]]; then
   echo "ERROR: -N/Slurm bundle count must be a positive integer: $bundle_count" >&2
   exit 1
fi
if [[ ! "$internal_parallelism" =~ ^[0-9]+$ ]] || [[ $internal_parallelism -lt 1 ]]; then
   echo "ERROR: SLURM_INTERNAL_PARALLELISM must be a positive integer: $internal_parallelism" >&2
   exit 1
fi

if [[ "${MPCLP_GENERATE_LEGACY_SLURM:-0}" == "1" ]]; then
   echo "ERROR: legacy cmd.sh Slurm generation is incompatible with backend-independent tasks.jsonl." >&2
   echo "Use research-os submit-tasks instead." >&2
   exit 1
elif [[ -f ${PWD}/submit_jobs_array_bundles.sh && "${MPCLP_GENERATE_LEGACY_SLURM:-0}" == "legacy-disabled" ]]; then
   cat > "$fn_submit" <<EOF
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${PWD}"
CMD_FILE="${dir_result}/cmd.sh"
RUNNER="\${RUNNER:-\${REPO_ROOT}/submit_jobs_array_bundles.sh}"
BUNDLE_COUNT="\${BUNDLE_COUNT:-${bundle_count}}"
INTERNAL_PARALLELISM="\${INTERNAL_PARALLELISM:-${internal_parallelism}}"
COMMAND_TIMEOUT="\${COMMAND_TIMEOUT:-${command_timeout}}"
WALLTIME_SECONDS="\${WALLTIME_SECONDS:-${walltime_seconds}}"
SLURM_TIME="\${SLURM_TIME:-${slurm_time}}"
USE_SRUN="\${USE_SRUN:-1}"

if [[ ! -f "\$CMD_FILE" ]]; then
  echo "ERROR: CMD_FILE does not exist: \$CMD_FILE" >&2
  exit 1
fi
if [[ ! -f "\$RUNNER" ]]; then
  echo "ERROR: Slurm array runner does not exist: \$RUNNER" >&2
  exit 1
fi

export CMD_FILE BUNDLE_COUNT INTERNAL_PARALLELISM COMMAND_TIMEOUT WALLTIME_SECONDS USE_SRUN
sbatch \\
  --array="1-\${BUNDLE_COUNT}%\${BUNDLE_COUNT}" \\
  --time="\${SLURM_TIME}" \\
  --export="ALL,CMD_FILE=\${CMD_FILE},BUNDLE_COUNT=\${BUNDLE_COUNT},INTERNAL_PARALLELISM=\${INTERNAL_PARALLELISM},COMMAND_TIMEOUT=\${COMMAND_TIMEOUT},WALLTIME_SECONDS=\${WALLTIME_SECONDS},USE_SRUN=\${USE_SRUN}" \\
  "\$RUNNER"
EOF
   chmod +x "$fn_submit"

   cat > "$fn_submit_runhub" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SUBMIT_SCRIPT="${fn_submit}"
RESULT_DIR="${dir_result}"
RUNHUB_RECORD="\${RUNHUB_RECORD:-\${RESULT_DIR}/runhub_record.json}"
REGISTER_RUNHUB_SCRIPT="\${REGISTER_RUNHUB_SCRIPT:-}"

submit_output="\$("\$SUBMIT_SCRIPT")"
printf "%s\\n" "\$submit_output"
job_id="\$(printf "%s\\n" "\$submit_output" | awk '/Submitted batch job/ {print \$NF; exit}')"
if [[ -z "\$job_id" ]]; then
  echo "ERROR: could not parse Slurm job id from sbatch output" >&2
  exit 1
fi

mkdir -p "\$RESULT_DIR"
export RUNHUB_RECORD
export RUNHUB_PROJECT="\${RUNHUB_PROJECT:-MPCLP}"
export RUNHUB_STATUS="\${RUNHUB_STATUS:-submitted}"
export RUNHUB_ETA="\${RUNHUB_ETA:-${total_hours}h}"
export RUNHUB_HOST="\${RUNHUB_HOST:-\$(hostname)}"
export RUNHUB_SCHEDULER="\${RUNHUB_SCHEDULER:-slurm}"
export RUNHUB_JOB_ID="\$job_id"
export RUNHUB_REMOTE_PATH="\${RUNHUB_REMOTE_PATH:-\$RESULT_DIR}"
export RUNHUB_LOCAL_PATH="\${RUNHUB_LOCAL_PATH:-${dir_result}}"
export RUNHUB_CHECK_CMD="\${RUNHUB_CHECK_CMD:-squeue -j \$job_id}"
export RUNHUB_FETCH_CMD="\${RUNHUB_FETCH_CMD:-manual: archive/fetch \$RESULT_DIR after completion}"
export RUNHUB_STATS_CMD="\${RUNHUB_STATS_CMD:-python3 scripts/report/make_facility_mixture_colocation_effects.py}"
export RUNHUB_REPORT_PATH="\${RUNHUB_REPORT_PATH:-output/2026-07-08_FacilityMixture_ColocEffect_High0105}"
export RUNHUB_BRANCH="\${RUNHUB_BRANCH:-${gitbranch}}"
export RUNHUB_COMMIT="\${RUNHUB_COMMIT:-${gitversion}}"
export RUNHUB_SOURCE_THREAD_ID="\${RUNHUB_SOURCE_THREAD_ID:-}"
export RUNHUB_SOURCE_THREAD_CWD="\${RUNHUB_SOURCE_THREAD_CWD:-${PWD}}"
export RUNHUB_AUTOMATION_KIND="\${RUNHUB_AUTOMATION_KIND:-codex_manual_followup}"
export RUNHUB_AUTOMATION_STATUS="\${RUNHUB_AUTOMATION_STATUS:-needed}"
export RUNHUB_REUSE_DECISION="\${RUNHUB_REUSE_DECISION:-new-only supplement}"
export RUNHUB_REUSE_REASON="\${RUNHUB_REUSE_REASON:-Generated cmd.sh contains only missing requested cases for this batch.}"
export RUNHUB_NOTES="\${RUNHUB_NOTES:-${runhub_notes}}"
export RUNHUB_COMMAND_COUNT="${job_count}"
export RUNHUB_CMD_FILE="${dir_result}/cmd.sh"
export RUNHUB_SUBMIT_SCRIPT="${fn_submit}"
export RUNHUB_ARRAY_BUNDLES="${bundle_count}"
export RUNHUB_INTERNAL_PARALLELISM="${internal_parallelism}"
export RUNHUB_COMMAND_TIMEOUT="${command_timeout}"
export RUNHUB_WALLTIME_SECONDS="${walltime_seconds}"

python3 - <<'PY'
import json
import os

record = {
    "project": os.environ["RUNHUB_PROJECT"],
    "status": os.environ["RUNHUB_STATUS"],
    "eta": os.environ.get("RUNHUB_ETA", ""),
    "host": os.environ.get("RUNHUB_HOST", ""),
    "scheduler": os.environ["RUNHUB_SCHEDULER"],
    "job_id": os.environ["RUNHUB_JOB_ID"],
    "remote_path": os.environ.get("RUNHUB_REMOTE_PATH", ""),
    "local_path": os.environ.get("RUNHUB_LOCAL_PATH", ""),
    "check_cmd": os.environ.get("RUNHUB_CHECK_CMD", ""),
    "fetch_cmd": os.environ.get("RUNHUB_FETCH_CMD", ""),
    "stats_cmd": os.environ.get("RUNHUB_STATS_CMD", ""),
    "report_path": os.environ.get("RUNHUB_REPORT_PATH", ""),
    "branch": os.environ.get("RUNHUB_BRANCH", ""),
    "commit": os.environ.get("RUNHUB_COMMIT", ""),
    "source_thread_id": os.environ.get("RUNHUB_SOURCE_THREAD_ID", ""),
    "source_thread_cwd": os.environ.get("RUNHUB_SOURCE_THREAD_CWD", ""),
    "automation_kind": os.environ.get("RUNHUB_AUTOMATION_KIND", ""),
    "automation_status": os.environ.get("RUNHUB_AUTOMATION_STATUS", ""),
    "reuse_decision": os.environ.get("RUNHUB_REUSE_DECISION", ""),
    "reuse_reason": os.environ.get("RUNHUB_REUSE_REASON", ""),
    "notes": os.environ.get("RUNHUB_NOTES", ""),
    "metadata": {
        "command_count": os.environ.get("RUNHUB_COMMAND_COUNT", ""),
        "cmd_file": os.environ.get("RUNHUB_CMD_FILE", ""),
        "submit_script": os.environ.get("RUNHUB_SUBMIT_SCRIPT", ""),
        "array_bundles": os.environ.get("RUNHUB_ARRAY_BUNDLES", ""),
        "internal_parallelism": os.environ.get("RUNHUB_INTERNAL_PARALLELISM", ""),
        "command_timeout_seconds": os.environ.get("RUNHUB_COMMAND_TIMEOUT", ""),
        "walltime_seconds": os.environ.get("RUNHUB_WALLTIME_SECONDS", ""),
    },
}

path = os.environ["RUNHUB_RECORD"]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({k: v for k, v in record.items() if v}, handle, indent=2)
    handle.write("\\n")
PY

echo "RUNHUB_RECORD_JSON=\$RUNHUB_RECORD"
echo "RUNHUB_RECORD_JSON_BEGIN"
cat "\$RUNHUB_RECORD"
echo "RUNHUB_RECORD_JSON_END"
if [[ "\${REGISTER_RUNHUB:-0}" == "1" ]]; then
  if [[ ! -f "\$REGISTER_RUNHUB_SCRIPT" ]]; then
    echo "ERROR: register script not found: \$REGISTER_RUNHUB_SCRIPT" >&2
    exit 1
  fi
  bash "\$REGISTER_RUNHUB_SCRIPT" "\$RUNHUB_RECORD"
fi
EOF
   chmod +x "$fn_submit_runhub"

   echo "Slurm array: --array=1-${bundle_count}%${bundle_count} --ntasks-per-task-runner=${internal_parallelism} --time=${slurm_time}"
   echo "             (${job_count} jobs, ${TIME_LIMIT}s each, ${global_parallelism} concurrent upper bound; queue time excluded)"
   echo "submit command: ${fn_submit_runhub}"
   echo "submit without registering: ${fn_submit}"
else
   echo "Research OS task submission:"
   echo "  research-os submit-tasks ${tasks_file} --project MGCLP --account <account> --workspace <workspace> --result-path <relative-result-path> --bundle-count ${bundle_count} --internal-parallelism ${internal_parallelism}"
   echo "(legacy cmd.sh Slurm helper generation is disabled)"
fi
