#!/bin/bash -e

build_dir=/opt/build
mounted_dir=/opt/server
spt_binary=SPT.Server.exe
uid=${UID:-1000}
gid=${GID:-1000}

backup_dir_name=${BACKUP_DIR:-backups}
backup_dir=$mounted_dir/$backup_dir_name

spt_backup_dir=$backup_dir/spt/$(date +%Y%m%dT%H:%M)
spt_version=3.9.8
spt_data_dir=$mounted_dir/SPT_Data
spt_core_config=$spt_data_dir/Server/configs/core.json

install_fika=${INSTALL_FIKA:-false}
fika_backup_dir=$backup_dir/fika/$(date +%Y%m%dT%H:%M)
fika_mod_dir=$mounted_dir/user/mods/fika-server
fika_version=${FIKA_VERSION:-v2.2.8}
fika_artifact=fika-server.zip
fika_release_url="https://github.com/project-fika/Fika-Server/releases/download/$fika_version/$fika_artifact"

auto_update_spt=${AUTO_UPDATE_SPT:-false}
auto_update_fika=${AUTO_UPDATE_FIKA:-false}

create_running_user() {
    echo "Checking running user/group: $uid:$gid"
    getent group $gid || groupadd -g $gid spt
    if [[ ! $(id -un $uid) ]]; then
        echo "User not found, creating user 'spt' with id $uid"
        useradd --create-home -u $uid -g $gid spt
    fi
}

validate() {
    # Must mount /opt/server directory, otherwise the serverfiles are in container and there's no persistence
    if [[ ! $(mount | grep $mounted_dir) ]]; then
        echo "Please mount a volume/directory from the host to $mounted_dir. This server container must store files on the host."
        echo "You can do this with docker run's -v flag e.g. '-v /path/on/host:/opt/server'"
        echo "or with docker-compose's 'volumes' directive"
        exit 1
    fi

    # Validate SPT version
    if [[ -d $spt_data_dir && -f $spt_core_config ]]; then
        echo "Validating SPT version"
        existing_spt_version=$(jq -r '.sptVersion' $spt_core_config)
        if [[ $existing_spt_version != "$spt_version" ]]; then
            try_update_spt $existing_spt_version
        fi
    fi

    # Validate fika version
    if [[ -d $fika_mod_dir && $install_fika == "true" ]]; then
        echo "Validating Fika version"
        existing_fika_version=$(jq -r '.version' $fika_mod_dir/package.json)
        if [[ "v$existing_fika_version" != $fika_version ]]; then
            try_update_fika
        fi
    fi
}

#####*##
# Fika #
########
get_and_install_fika() {
    echo "Installing Fika servermod version $fika_version"
    # Assumes fika_server.zip artifact contains user/mods/fika-server
    curl -sL $fika_release_url -O
    unzip -q $fika_artifact -d $mounted_dir
    rm $fika_artifact
}

backup_fika() {
    cp -r $fika_mod_dir $fika_backup_dir
}

try_update_fika() {
    if [[ "$auto_update_fika" != "true" ]]; then
        echo "Fika Version mismatch: Fika install requested but existing fika mod server is v$existing_fika_version while this image expects $fika_version"
        echo "Aborting"
        exit 1
    fi

    # Backup entire fika servermod, then delete and update servermod
    backup_fika
    rm -r $fika_mod_dir
    get_and_install_fika
    # restore config
    cp $fika_backup_dir/fika-server/assets/config.jsonc $fika_mod_dir/assets/config.jsonc
}

#######
# SPT #
#######
make_and_own_spt_dirs() {
    mkdir -p $mounted_dir/user/mods
    mkdir -p $mounted_dir/user/profiles
    chown -R ${uid}:${gid} $mounted_dir
}

install_spt() {
    cp -r $build_dir/* $mounted_dir
    make_and_own_spt_dirs
}

# TODO Anticipate BepInEx too, for Corter-ModSync
backup_spt_user_dirs() {
    cp -r $mounted_dir/user $spt_backup_dir/
}

try_update_spt() {
    if [[ "$auto_update_spt" != "true" ]]; then
        echo "SPT Version mismatch: existing server files are SPT $existing_spt_version while this image expects $spt_version"
        echo "Aborting"
        exit 1
    fi

    # Backup SPT, install new version, then halt
    backup_spt_user_dirs
    install_spt
    echo "SPT update completed. We moved from $1 to $spt_version"
    echo "WARNING: The user folder has been backed up to $spt_backup_dir but otherwise has been left untouched in the server dir."
    echo "Please verify your existing mods and profile work with this new SPT version! You may want to delete the mods directory and start from scratch"
    echo "Restart this container to bring the server back up"
}

validate

# If no server binary in this directory, copy our built files in here and run it once
if [[ ! -f "$mounted_dir/$spt_binary" ]]; then
    echo "Server files not found, initializing first boot..."
    install_spt
else
    echo "Found server files, skipping init"
fi

# Install fika if requested. Run each boot to support installing in existing serverfiles that don't have fika installed
if [[ "$install_fika" == "true" ]]; then
    if [[ ! -d $fika_mod_dir ]]; then
        get_and_install_fika
    else 
        echo "Fika install requested but Fika server mod dir already exists, skipping Fika installation"
    fi
fi

create_running_user

# Own mounted files as running user
# TODO Do we want to do this? Would it be annoying if user expects files ownership not to change?
# downside is we are running as a specific user so any files created by the server binary will be owned by the running user
chown -R ${uid}:${gid} $mounted_dir

su - $(id -nu $uid) -c "cd $mounted_dir && ./SPT.Server.exe"
