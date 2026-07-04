#!/usr/bin/env bash
set -euo pipefail

# Full AmneziaWG installer for this script bundle.
# Run from vpsfiles/amnezia-scripts, then add clients with ./add-client.sh.

AWG_MTU_DEFAULT="1280"
AWG_I1_DEFAULT="<b 0xc70000000108ce1bf31eec7d93360000449e227e4596ed7f75c4d35ce31880b4133107c822c6355b51f0d7c1bba96d5c210a48aca01885fed0871cfc37d59137d73b506dc013bb4a13c060ca5b04b7ae215af71e37d6e8ff1db235f9fe0c25cb8b492471054a7c8d0d6077d430d07f6e87a8699287f6e69f54263c7334a8e144a29851429bf2e350e519445172d36953e96085110ce1fb641e5efad42c0feb4711ece959b72cc4d6f3c1e83251adb572b921534f6ac4b10927167f41fe50040a75acef62f45bded67c0b45b9d655ce374589cad6f568b8475b2e8921ff98628f86ff2eb5bcce6f3ddb7dc89e37c5b5e78ddc8d93a58896e530b5f9f1448ab3b7a1d1f24a63bf981634f6183a21af310ffa52e9ddf5521561760288669de01a5f2f1a4f922e68d0592026bbe4329b654d4f5d6ace4f6a23b8560b720a5350691c0037b10acfac9726add44e7d3e880ee6f3b0d6429ff33655c297fee786bb5ac032e48d2062cd45e305e6d8d8b82bfbf0fdbc5ec09943d1ad02b0b5868ac4b24bb10255196be883562c35a713002014016b8cc5224768b3d330016cf8ed9300fe6bf39b4b19b3667cddc6e7c7ebe4437a58862606a2a66bd4184b09ab9d2cd3d3faed4d2ab71dd821422a9540c4c5fa2a9b2e6693d411a22854a8e541ed930796521f03a54254074bc4c5bca152a1723260e7d70a24d49720acc544b41359cfc252385bda7de7d05878ac0ea0343c77715e145160e6562161dfe2024846dfda3ce99068817a2418e66e4f37dea40a21251c8a034f83145071d93baadf050ca0f95dc9ce2338fb082d64fbc8faba905cec66e65c0e1f9b003c32c943381282d4ab09bef9b6813ff3ff5118623d2617867e25f0601df583c3ac51bc6303f79e68d8f8de4b8363ec9c7728b3ec5fcd5274edfca2a42f2727aa223c557afb33f5bea4f64aeb252c0150ed734d4d8eccb257824e8e090f65029a3a042a51e5cc8767408ae07d55da8507e4d009ae72c47ddb138df3cab6cc023df2532f88fb5a4c4bd917fafde0f3134be09231c389c70bc55cb95a779615e8e0a76a2b4d943aabfde0e394c985c0cb0376930f92c5b6998ef49ff4a13652b787503f55c4e3d8eebd6e1bc6db3a6d405d8405bd7a8db7cefc64d16e0d105a468f3d33d29e5744a24c4ac43ce0eb1bf6b559aed520b91108cda2de6e2c4f14bc4f4dc58712580e07d217c8cca1aaf7ac04bab3e7b1008b966f1ed4fba3fd93a0a9d3a27127e7aa587fbcc60d548300146bdc126982a58ff5342fc41a43f83a3d2722a26645bc961894e339b953e78ab395ff2fb854247ad06d446cc2944a1aefb90573115dc198f5c1efbc22bc6d7a74e41e666a643d5f85f57fde81b87ceff95353d22ae8bab11684180dd142642894d8dc34e402f802c2fd4a73508ca99124e428d67437c871dd96e506ffc39c0fc401f666b437adca41fd563cbcfd0fa22fbbf8112979c4e677fb533d981745cceed0fe96da6cc0593c430bbb71bcbf924f70b4547b0bb4d41c94a09a9ef1147935a5c75bb2f721fbd24ea6a9f5c9331187490ffa6d4e34e6bb30c2c54a0344724f01088fb2751a486f425362741664efb287bce66c4a544c96fa8b124d3c6b9eaca170c0b530799a6e878a57f402eb0016cf2689d55c76b2a91285e2273763f3afc5bc9398273f5338a06d>"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=amnezia-scripts/common.sh
. "${SCRIPT_DIR}/common.sh"
SERVER_TEMPLATE="${SCRIPT_DIR}/awg0-server.example.conf"
CLIENT_TEMPLATE="${SCRIPT_DIR}/awg0-client.example.conf"
LAST_IP_FILE="${SCRIPT_DIR}/last-ip.txt"
LAST_IP6_FILE="${SCRIPT_DIR}/last-ip6.txt"
ENDPOINT_FILE="${SCRIPT_DIR}/server-endpoint.txt"
ENDPOINT6_FILE="${SCRIPT_DIR}/server-endpoint6.txt"
OBFUSCATION_FILE="${SCRIPT_DIR}/obfuscation.env"

AWG_IF="${AWG_IF:-${AWG_IF_DEFAULT}}"
AWG_PORT="${AWG_PORT:-${AWG_PORT_DEFAULT}}"
AWG_NET="${AWG_NET:-${AWG_NET_DEFAULT}}"
AWG_NET6="${AWG_NET6:-${AWG_NET6_DEFAULT}}"
AWG_SERVER_IP="${AWG_SERVER_IP:-${AWG_SERVER_IP_DEFAULT}}"
AWG_SERVER_IP6="${AWG_SERVER_IP6:-${AWG_SERVER_IP6_DEFAULT}}"
AWG_ENDPOINT="${AWG_ENDPOINT:-}"
AWG_ENDPOINT6="${AWG_ENDPOINT6:-}"
AWG_MTU="${AWG_MTU:-${AWG_MTU_DEFAULT}}"
AWG_I1="${AWG_I1:-${AWG_I1_DEFAULT}}"
SERVER_IF="${SERVER_IF:-}"
BACKUP_ROOT="${BACKUP_ROOT:-${SCRIPT_DIR}/install-backups}"
AWG_PREFIX="24"
AWG_PREFIX6="64"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=core/install.sh
. "${REPO_ROOT}/core/install.sh"
require_root() {
  vps_require_root "sudo bash ${0}"
}

require_files() {
  local missing=0

  for file in \
    "${SERVER_TEMPLATE}" \
    "${CLIENT_TEMPLATE}" \
    "${SCRIPT_DIR}/add-client.sh" \
    "${SCRIPT_DIR}/add-peer.sh" \
    "${SCRIPT_DIR}/remove-client.sh" \
    "${SCRIPT_DIR}/remove-peer.sh" \
    "${SCRIPT_DIR}/update.sh" \
    "${SCRIPT_DIR}/uninstall.sh"; do
    if [[ ! -f "${file}" ]]; then
      echo "ERROR: required file is missing: ${file}"
      missing=1
    fi
  done

  if [[ "${missing}" -ne 0 ]]; then
    exit 1
  fi
}

require_supported_os() {
  vps_require_supported_apt_os
}

prompt() {
  vps_prompt "$@"
}

confirm() {
  vps_confirm "$@"
}

die() {
  vps_die "$@"
}

detect_server_if() {
  vps_detect_server_if
}

detect_public_ip() {
  vps_detect_public_ip
}

detect_public_ip6() {
  vps_detect_public_ip6
}

install_packages() {
  local os_id=""
  local os_like=""

  # shellcheck source=/dev/null
  . /etc/os-release
  os_id="${ID:-}"
  os_like="${ID_LIKE:-}"

  vps_install_packages \
    curl \
    gnupg2 \
    iproute2 \
    iptables \
    "linux-headers-$(uname -r)" \
    python3-launchpadlib \
    software-properties-common \
    ufw

  if [[ "${os_id}" == "ubuntu" || "${os_like}" == *"ubuntu"* ]]; then
    add-apt-repository -y ppa:amnezia/ppa
  elif [[ "${os_id}" == "debian" || "${os_like}" == *"debian"* ]]; then
    apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 57290828
    printf 'deb https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main\n' > /etc/apt/sources.list.d/amneziawg-ppa.list
    printf 'deb-src https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main\n' >> /etc/apt/sources.list.d/amneziawg-ppa.list
  else
    die "unsupported OS: ${os_id:-unknown}; this installer supports Debian/Ubuntu only"
  fi

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y amneziawg
  vps_require_commands awg awg-quick
}

backup_existing_configs() {
  local timestamp=""
  local backup_dir=""
  local found=0
  local path=""

  timestamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="${BACKUP_ROOT}/${timestamp}"

  for path in \
    "${AWG_DIR}/${AWG_IF}.conf" \
    "${AWG_DIR}/server_private_key" \
    "${AWG_DIR}/server_public_key" \
    "${LAST_IP_FILE}" \
    "${LAST_IP6_FILE}" \
    "${ENDPOINT_FILE}" \
    "${ENDPOINT6_FILE}" \
    "${SCRIPT_DIR}/server-port.txt" \
    "${SCRIPT_DIR}/server-interface.txt" \
    "${SCRIPT_DIR}/server-net.txt" \
    "${SCRIPT_DIR}/server-net6.txt" \
    "${OBFUSCATION_FILE}"; do
    if [[ -e "${path}" ]]; then
      found=1
      break
    fi
  done
  if [[ -d "${CLIENTS_DIR}" && -n "$(find "${CLIENTS_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    found=1
  fi

  if [[ "${found}" -eq 0 ]]; then
    return 0
  fi

  echo
  echo "Existing AmneziaWG/script config was found."
  echo "Backup destination: ${backup_dir}"
  if ! confirm "Back up existing config before continuing?"; then
    echo "Aborted before making changes."
    exit 1
  fi

  mkdir -p "${backup_dir}/etc-amneziawg" "${backup_dir}/script-files"

  for path in "${AWG_DIR}/${AWG_IF}.conf" "${AWG_DIR}/server_private_key" "${AWG_DIR}/server_public_key"; do
    if [[ -e "${path}" ]]; then
      cp -a "${path}" "${backup_dir}/etc-amneziawg/"
    fi
  done
  for path in \
    "${LAST_IP_FILE}" \
    "${LAST_IP6_FILE}" \
    "${ENDPOINT_FILE}" \
    "${ENDPOINT6_FILE}" \
    "${SCRIPT_DIR}/server-port.txt" \
    "${SCRIPT_DIR}/server-interface.txt" \
    "${SCRIPT_DIR}/server-net.txt" \
    "${SCRIPT_DIR}/server-net6.txt" \
    "${OBFUSCATION_FILE}"; do
    if [[ -e "${path}" ]]; then
      cp -a "${path}" "${backup_dir}/script-files/"
    fi
  done
  if [[ -d "${CLIENTS_DIR}" ]]; then
    cp -a "${CLIENTS_DIR}" "${backup_dir}/script-files/"
  fi

  echo "Backup complete: ${backup_dir}"
}

stop_existing_amneziawg() {
  if systemctl is-active --quiet "awg-quick@${AWG_IF}"; then
    echo "Stopping active awg-quick@${AWG_IF} before replacing config..."
    systemctl stop "awg-quick@${AWG_IF}"
  fi
}

enable_ip_forwarding() {
  vps_enable_sysctl_file "${SYSCTL_FILE}" $'net.ipv4.ip_forward=1\nnet.ipv6.conf.all.forwarding=1\n'
}

generate_server_keys() {
  mkdir -p "${AWG_DIR}"
  chmod 700 "${AWG_DIR}"

  (
    umask 077
    awg genkey | tee "${AWG_DIR}/server_private_key" | awg pubkey > "${AWG_DIR}/server_public_key"
  )
  chmod 600 "${AWG_DIR}/server_private_key" "${AWG_DIR}/server_public_key"
}

random_int() {
  local min="$1"
  local max="$2"
  local rand=""

  rand="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
  if [[ -z "${rand}" ]]; then
    rand="${RANDOM}"
  fi

  printf '%s\n' "$((min + rand % (max - min + 1)))"
}

validate_int() {
  local name="$1"
  local value="$2"
  local min="$3"
  local max="$4"

  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} must be an integer"
  (( value >= min && value <= max )) || die "${name} must be between ${min} and ${max}"
}

parse_header_range() {
  local value="$1"
  local start_var="$2"
  local end_var="$3"
  local start=""
  local end=""

  if [[ "${value}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    start="${BASH_REMATCH[1]}"
    end="${BASH_REMATCH[2]}"
  elif [[ "${value}" =~ ^[0-9]+$ ]]; then
    start="${value}"
    end="${value}"
  else
    return 1
  fi

  validate_int "header range start" "${start}" 0 4294967295
  validate_int "header range end" "${end}" 0 4294967295
  (( start <= end )) || return 1

  printf -v "${start_var}" '%s' "${start}"
  printf -v "${end_var}" '%s' "${end}"
}

ranges_overlap() {
  local a_start="$1"
  local a_end="$2"
  local b_start="$3"
  local b_end="$4"

  (( a_start <= b_end && b_start <= a_end ))
}

i1_packet_size() {
  local rest="$1"
  local tag=""
  local hex=""
  local bytes=""
  local total=0

  while [[ -n "${rest}" ]]; do
    if [[ "${rest}" =~ ^(<[^>]+>)(.*)$ ]]; then
      tag="${BASH_REMATCH[1]}"
      rest="${BASH_REMATCH[2]}"
    else
      return 1
    fi

    if [[ "${tag}" =~ ^\<b[[:space:]]0x([0-9A-Fa-f]+)\>$ ]]; then
      hex="${BASH_REMATCH[1]}"
      (( ${#hex} % 2 == 0 )) || return 1
      total=$((total + ${#hex} / 2))
    elif [[ "${tag}" =~ ^\<r[[:space:]]([0-9]+)\>$ ]]; then
      bytes="${BASH_REMATCH[1]}"
      total=$((total + bytes))
    elif [[ "${tag}" =~ ^\<rd[[:space:]]([0-9]+)\>$ ]]; then
      bytes="${BASH_REMATCH[1]}"
      total=$((total + bytes))
    elif [[ "${tag}" =~ ^\<rc[[:space:]]([0-9]+)\>$ ]]; then
      bytes="${BASH_REMATCH[1]}"
      total=$((total + bytes))
    elif [[ "${tag}" == "<t>" ]]; then
      total=$((total + 4))
    else
      return 1
    fi
  done

  printf '%s\n' "${total}"
}

generate_obfuscation_params() {
  local h_start=""
  local h_width=""
  local jmax_max=1024
  local jmin_max=512

  validate_int "AWG_MTU" "${AWG_MTU}" 576 9000
  if (( AWG_MTU - 1 < jmax_max )); then
    jmax_max="$((AWG_MTU - 1))"
  fi
  if (( jmax_max - 1 < jmin_max )); then
    jmin_max="$((jmax_max - 1))"
  fi
  if [[ -n "${AWG_JMIN:-}" ]]; then
    validate_int "AWG_JMIN" "${AWG_JMIN}" 64 "${jmin_max}"
  fi

  AWG_JC="${AWG_JC:-$(random_int 4 10)}"
  AWG_JMIN="${AWG_JMIN:-$(random_int 64 "${jmin_max}")}"
  AWG_JMAX="${AWG_JMAX:-$(random_int "$((AWG_JMIN + 1))" "${jmax_max}")}"
  AWG_S1="${AWG_S1:-$(random_int 1 64)}"
  AWG_S2="${AWG_S2:-$(random_int 1 64)}"
  AWG_S3="${AWG_S3:-$(random_int 1 64)}"
  AWG_S4="${AWG_S4:-$(random_int 1 32)}"

  if [[ -z "${AWG_H1:-}" ]]; then
    h_start="$(random_int 100000000 199999900)"
    h_width="$(random_int 8 64)"
    AWG_H1="${h_start}-$((h_start + h_width))"
  fi
  if [[ -z "${AWG_H2:-}" ]]; then
    h_start="$(random_int 1200000000 1299999900)"
    h_width="$(random_int 8 64)"
    AWG_H2="${h_start}-$((h_start + h_width))"
  fi
  if [[ -z "${AWG_H3:-}" ]]; then
    h_start="$(random_int 2300000000 2399999900)"
    h_width="$(random_int 8 64)"
    AWG_H3="${h_start}-$((h_start + h_width))"
  fi
  if [[ -z "${AWG_H4:-}" ]]; then
    h_start="$(random_int 3400000000 3499999900)"
    h_width="$(random_int 8 64)"
    AWG_H4="${h_start}-$((h_start + h_width))"
  fi
}

validate_obfuscation_params() {
  local h1_start="" h1_end=""
  local h2_start="" h2_end=""
  local h3_start="" h3_end=""
  local h4_start="" h4_end=""
  local i1_size=""

  validate_int "AWG_MTU" "${AWG_MTU}" 576 9000
  validate_int "AWG_JC" "${AWG_JC}" 4 10
  validate_int "AWG_JMIN" "${AWG_JMIN}" 64 1024
  validate_int "AWG_JMAX" "${AWG_JMAX}" 64 1024
  (( AWG_JMIN < AWG_JMAX )) || die "AWG_JMIN must be less than AWG_JMAX"
  (( AWG_JMAX < AWG_MTU )) || die "AWG_JMAX must be less than AWG_MTU"
  validate_int "AWG_S1" "${AWG_S1}" 1 64
  validate_int "AWG_S2" "${AWG_S2}" 1 64
  validate_int "AWG_S3" "${AWG_S3}" 1 64
  validate_int "AWG_S4" "${AWG_S4}" 1 32

  parse_header_range "${AWG_H1}" h1_start h1_end || die "AWG_H1 must be a uint32 value or range x-y"
  parse_header_range "${AWG_H2}" h2_start h2_end || die "AWG_H2 must be a uint32 value or range x-y"
  parse_header_range "${AWG_H3}" h3_start h3_end || die "AWG_H3 must be a uint32 value or range x-y"
  parse_header_range "${AWG_H4}" h4_start h4_end || die "AWG_H4 must be a uint32 value or range x-y"

  ranges_overlap "${h1_start}" "${h1_end}" "${h2_start}" "${h2_end}" && die "AWG_H1 overlaps AWG_H2"
  ranges_overlap "${h1_start}" "${h1_end}" "${h3_start}" "${h3_end}" && die "AWG_H1 overlaps AWG_H3"
  ranges_overlap "${h1_start}" "${h1_end}" "${h4_start}" "${h4_end}" && die "AWG_H1 overlaps AWG_H4"
  ranges_overlap "${h2_start}" "${h2_end}" "${h3_start}" "${h3_end}" && die "AWG_H2 overlaps AWG_H3"
  ranges_overlap "${h2_start}" "${h2_end}" "${h4_start}" "${h4_end}" && die "AWG_H2 overlaps AWG_H4"
  ranges_overlap "${h3_start}" "${h3_end}" "${h4_start}" "${h4_end}" && die "AWG_H3 overlaps AWG_H4"

  i1_size="$(i1_packet_size "${AWG_I1}")" || die "AWG_I1 must use valid CPS tags"
  (( i1_size < AWG_MTU )) || die "AWG_I1 packet size ${i1_size} must be less than AWG_MTU ${AWG_MTU}"
}

write_env_line() {
  local name="$1"
  local value="$2"

  {
    printf "%s='" "${name}"
    printf '%s' "${value}" | sed "s/'/'\\\\''/g"
    printf "'\n"
  } >> "${OBFUSCATION_FILE}"
}

save_obfuscation_params() {
  : > "${OBFUSCATION_FILE}"
  chmod 600 "${OBFUSCATION_FILE}"
  write_env_line AWG_MTU "${AWG_MTU}"
  write_env_line AWG_JC "${AWG_JC}"
  write_env_line AWG_JMIN "${AWG_JMIN}"
  write_env_line AWG_JMAX "${AWG_JMAX}"
  write_env_line AWG_S1 "${AWG_S1}"
  write_env_line AWG_S2 "${AWG_S2}"
  write_env_line AWG_S3 "${AWG_S3}"
  write_env_line AWG_S4 "${AWG_S4}"
  write_env_line AWG_H1 "${AWG_H1}"
  write_env_line AWG_H2 "${AWG_H2}"
  write_env_line AWG_H3 "${AWG_H3}"
  write_env_line AWG_H4 "${AWG_H4}"
  write_env_line AWG_I1 "${AWG_I1}"
}

sed_escape() {
  vps_sed_escape "$1"
}

render_server_config() {
  local server_private_key=""

  server_private_key="$(cat "${AWG_DIR}/server_private_key")"
  if [[ "${AWG_NET}" == */* ]]; then
    AWG_PREFIX="${AWG_NET##*/}"
  fi
  if [[ "${AWG_NET6}" == */* ]]; then
    AWG_PREFIX6="${AWG_NET6##*/}"
  fi

  sed \
    -e "s|:SERVER_PRIV_KEY:|$(sed_escape "${server_private_key}")|g" \
    -e "s|:SERVER_IP:|$(sed_escape "${AWG_SERVER_IP}")|g" \
    -e "s|:SERVER_IP6:|$(sed_escape "${AWG_SERVER_IP6}")|g" \
    -e "s|:SERVER_PREFIX:|$(sed_escape "${AWG_PREFIX}")|g" \
    -e "s|:SERVER_PREFIX6:|$(sed_escape "${AWG_PREFIX6}")|g" \
    -e "s|:SERVER_PORT:|$(sed_escape "${AWG_PORT}")|g" \
    -e "s|:SERVER_NET:|$(sed_escape "${AWG_NET}")|g" \
    -e "s|:SERVER_NET6:|$(sed_escape "${AWG_NET6}")|g" \
    -e "s|:SERVER_IF:|$(sed_escape "${SERVER_IF}")|g" \
    -e "s|:AWG_MTU:|$(sed_escape "${AWG_MTU}")|g" \
    -e "s|:AWG_JC:|$(sed_escape "${AWG_JC}")|g" \
    -e "s|:AWG_JMIN:|$(sed_escape "${AWG_JMIN}")|g" \
    -e "s|:AWG_JMAX:|$(sed_escape "${AWG_JMAX}")|g" \
    -e "s|:AWG_S1:|$(sed_escape "${AWG_S1}")|g" \
    -e "s|:AWG_S2:|$(sed_escape "${AWG_S2}")|g" \
    -e "s|:AWG_S3:|$(sed_escape "${AWG_S3}")|g" \
    -e "s|:AWG_S4:|$(sed_escape "${AWG_S4}")|g" \
    -e "s|:AWG_H1:|$(sed_escape "${AWG_H1}")|g" \
    -e "s|:AWG_H2:|$(sed_escape "${AWG_H2}")|g" \
    -e "s|:AWG_H3:|$(sed_escape "${AWG_H3}")|g" \
    -e "s|:AWG_H4:|$(sed_escape "${AWG_H4}")|g" \
    -e "s|:AWG_I1:|$(sed_escape "${AWG_I1}")|g" \
    "${SERVER_TEMPLATE}" > "${AWG_DIR}/${AWG_IF}.conf"

  chmod 600 "${AWG_DIR}/${AWG_IF}.conf"
}

prepare_script_state() {
  mkdir -p "${CLIENTS_DIR}"

  printf '%s\n' "${AWG_SERVER_IP}" > "${LAST_IP_FILE}"
  printf '%s\n' "${AWG_SERVER_IP6}" > "${LAST_IP6_FILE}"
  printf '%s\n' "${AWG_ENDPOINT}" > "${ENDPOINT_FILE}"
  printf '%s\n' "${AWG_ENDPOINT6}" > "${ENDPOINT6_FILE}"
  printf '%s\n' "${AWG_PORT}" > "${SCRIPT_DIR}/server-port.txt"
  printf '%s\n' "${AWG_IF}" > "${SCRIPT_DIR}/server-interface.txt"
  printf '%s\n' "${AWG_NET}" > "${SCRIPT_DIR}/server-net.txt"
  printf '%s\n' "${AWG_NET6}" > "${SCRIPT_DIR}/server-net6.txt"

  chmod +x \
    "${SCRIPT_DIR}/add-client.sh" \
    "${SCRIPT_DIR}/add-peer.sh" \
    "${SCRIPT_DIR}/remove-client.sh" \
    "${SCRIPT_DIR}/remove-peer.sh" \
    "${SCRIPT_DIR}/update.sh" \
    "${SCRIPT_DIR}/uninstall.sh" 2>/dev/null || true
}

setup_firewall() {
  vps_ufw_allow "${AWG_PORT}" "udp"
  vps_enable_ufw_if_needed "Skipped enabling UFW. The AmneziaWG UDP port was still added to UFW rules."
}

start_amneziawg() {
  vps_systemctl_enable_restart "awg-quick@${AWG_IF}"
}

collect_settings() {
  local detected_if=""
  local detected_endpoint=""
  local detected_endpoint6=""

  detected_if="$(detect_server_if)"
  detected_endpoint="$(detect_public_ip)"
  detected_endpoint6="$(detect_public_ip6)"

  prompt AWG_IF "AmneziaWG interface name" "${AWG_IF}"
  prompt AWG_PORT "AmneziaWG UDP port" "${AWG_PORT}"
  vps_validate_port "${AWG_PORT}"
  prompt AWG_NET "AmneziaWG IPv4 VPN subnet" "${AWG_NET}"
  prompt AWG_SERVER_IP "AmneziaWG server IPv4 VPN IP" "${AWG_SERVER_IP}"
  prompt AWG_NET6 "AmneziaWG IPv6 VPN subnet" "${AWG_NET6}"
  prompt AWG_SERVER_IP6 "AmneziaWG server IPv6 VPN IP" "${AWG_SERVER_IP6}"
  prompt AWG_MTU "AmneziaWG MTU" "${AWG_MTU}"
  prompt SERVER_IF "Public network interface for NAT" "${SERVER_IF:-${detected_if:-eth0}}"
  prompt AWG_ENDPOINT "Public endpoint clients should connect to" "${AWG_ENDPOINT:-${detected_endpoint:-$(hostname -f)}}"
  prompt AWG_ENDPOINT6 "Public IPv6 endpoint clients can connect to" "${AWG_ENDPOINT6:-${detected_endpoint6}}"
  [[ -n "${AWG_ENDPOINT}" ]] || vps_die "public endpoint cannot be empty"
}

print_summary() {
  echo
  echo "============================================================"
  echo "AmneziaWG installation complete."
  echo "============================================================"
  echo
  echo "Server config:     ${AWG_DIR}/${AWG_IF}.conf"
  echo "Server IPv4 IP:    ${AWG_SERVER_IP}"
  echo "Server IPv6 IP:    ${AWG_SERVER_IP6}"
  echo "IPv4 VPN subnet:   ${AWG_NET}"
  echo "IPv6 VPN subnet:   ${AWG_NET6}"
  echo "UDP port:          ${AWG_PORT}"
  echo "MTU:               ${AWG_MTU}"
  echo "Public interface:  ${SERVER_IF}"
  echo "Client IPv4 endpoint: ${AWG_ENDPOINT}"
  echo "Client IPv6 endpoint: ${AWG_ENDPOINT6}"
  echo "Obfuscation state: ${OBFUSCATION_FILE}"
  echo
  echo "Add clients with:"
  echo "  cd ${SCRIPT_DIR}"
  echo "  sudo ./add-client.sh phone             # create and add client"
  echo "  sudo ./add-client.sh --verbose phone   # also print live interface output"
  echo "  sudo ./add-client.sh --ipv6-endpoint phone # create client using IPv6 endpoint"
  echo "  sudo ./add-peer.sh phone               # add an existing client to ${AWG_IF}.conf and live ${AWG_IF}"
  echo "  sudo ./add-peer.sh --config-only phone # add an existing client to ${AWG_IF}.conf only"
  echo "  sudo ./add-peer.sh --live-only phone   # add an existing client to live ${AWG_IF} only"
  echo "  sudo ./remove-client.sh phone          # remove peer and client files"
  echo "  sudo ./remove-peer.sh phone            # remove an existing client from ${AWG_IF}.conf and live ${AWG_IF}"
  echo "  sudo ./remove-peer.sh --config-only phone # remove an existing client from ${AWG_IF}.conf only"
  echo "  sudo ./remove-peer.sh --live-only phone # remove an existing client from live ${AWG_IF} only"
  echo "  sudo ./uninstall.sh                    # remove script-created AmneziaWG data"
  echo
  echo "Check status with:"
  echo "  awg"
  echo "  sudo systemctl status awg-quick@${AWG_IF}"
}

main() {
  require_root
  require_files
  require_supported_os

  echo "AmneziaWG full installation"
  echo
  collect_settings
  generate_obfuscation_params
  validate_obfuscation_params

  echo
  echo "This will install AmneziaWG packages, back up existing AWG config if present,"
  echo "write ${AWG_DIR}/${AWG_IF}.conf, save obfuscation parameters,"
  echo "enable IPv4/IPv6 forwarding, configure UFW, and start awg-quick@${AWG_IF}."
  if ! confirm "Continue?"; then
    echo "Aborted before making changes."
    exit 1
  fi

  backup_existing_configs
  install_packages
  stop_existing_amneziawg
  enable_ip_forwarding
  generate_server_keys
  save_obfuscation_params
  render_server_config
  prepare_script_state
  setup_firewall
  start_amneziawg
  print_summary
}

main "$@"
