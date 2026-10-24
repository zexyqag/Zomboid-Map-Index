FROM eclipse-temurin:25-jdk AS rooms
COPY worker/ReadSpawnRooms.java /src/
RUN javac -Xlint:all,-serial -Werror -d /src/classes /src/ReadSpawnRooms.java \
  && jar --create --file /src/read_spawn_rooms.jar --main-class ReadSpawnRooms -C /src/classes .

FROM cm2network/steamcmd:root

RUN apt-get update \
  && apt-get install -y --no-install-recommends --no-install-suggests git jq openssh-client \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Created here so a new named volume starts out owned by the steam user.
RUN mkdir -p /cache /items /keys /repo \
  && chown "${USER}:${USER}" /cache /items /keys /repo

# Docker 29's default seccomp profile refuses the sockets of 32-bit programs, and SteamCMD is one until it updates
# itself to Valve's 64-bit build. So it updates here, as the base image's 32-bit build, and STEAM_PLATFORM makes
# steamcmd.sh start the 64-bit build from then on.
ENV STEAM_PLATFORM=linux64
RUN su "${USER}" -c "STEAM_PLATFORM=linux32 '${STEAMCMDDIR}/steamcmd.sh' +quit" \
  && test -x "${STEAMCMDDIR}/linux64/steamcmd"

COPY --from=eclipse-temurin:25-jre /opt/java/openjdk /opt/java/openjdk
ENV PATH="/opt/java/openjdk/bin:${PATH}" ROOMS_READER=/worker/read_spawn_rooms.jar
COPY --from=rooms /src/read_spawn_rooms.jar /worker/read_spawn_rooms.jar
COPY --chmod=755 ci/lib.sh /worker/ci/
COPY --chmod=755 worker/commit.sh worker/index_item.sh worker/serve.sh worker/work.sh /worker/worker/
USER ${USER}
ENTRYPOINT ["/worker/worker/work.sh"]
