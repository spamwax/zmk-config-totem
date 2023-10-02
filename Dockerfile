ARG zmk_type=dev
ARG zmk_tag=stable

FROM docker.io/zmkfirmware/zmk-${zmk_type}-arm:${zmk_tag}

RUN apt -y update && apt -y install jq
RUN python3 -m pip install remarshal
