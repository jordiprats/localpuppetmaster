#!/bin/bash

EXIT_CODE_PUPPET=0
BUNDLE_MODE=0

unpack_bundle()
{
  if [ "$BUNDLE_MODE" -eq 1 ];
  then
    mkdir -p $DIR/bundle

    THIS=$0
    SKIP=$(awk '/^__AQUI_BUNDLE_TGZ__/ { print NR + 1; exit 0; }' $THIS)

    tail -n +$SKIP $THIS | base64 -d > $DIR/bundle/bundle.tgz

    tar xf $DIR/bundle/bundle.tgz -C $DIR

    if [ -z "$SITEPP" ] && [ -f "$DIR/site.pp" ];
    then
      SITEPP="$DIR/site.pp"
    fi

    if [ -z "$HIERAYAML" ] && [ -f "$DIR/hiera.yaml" ];
    then
      HIERAYAML="$DIR/hiera.yaml"
    fi

  fi
}

forge_install()
{
  $PUPPETBIN module --modulepath=$DIR/modules uninstall $1 --force
  $PUPPETBIN module --modulepath=$DIR/modules install $1
}

tarball_install()
{
  tar xzf $1 -C $DIR/pkg

  if [ $? -ne 0 ];
  then
    echo "error uncompressing modules"
    exit 1
  fi

  if [ -z "$2" ];
  then
    find $DIR/pkg -name \*tar\.gz -exec $PUPPETBIN module --modulepath=$DIR/modules install {} \;
  else
    if [ ! -z "$(find $DIR/pkg -name $2\*)" ];
    then
      $PUPPETBIN module --modulepath=$DIR/modules uninstall $2 --force
      find $DIR/pkg -name $2\* -exec $PUPPETBIN module --modulepath=$DIR/modules install {} \;
    else
      echo "module not found - aborting"
      exit 1
    fi
  fi
}

puppet_check()
{
  PUPPETBIN=$(which puppet 2>/dev/null)

  if [ -z "$PUPPETBIN" ];
  then
    if [ -e "/opt/puppetlabs/bin/puppet" ];
    then
      PUPPETBIN='/opt/puppetlabs/bin/puppet'
    else
      echo "puppet not found"
      exit 1
    fi
  fi
}

r10k_check()
{
  R10KBIN=$(which r10k 2>/dev/null)

  if [ -z "$R10KBIN" ];
  then
    if [ -e "/opt/puppetlabs/bin/r10k" ];
    then
      R10KBIN='/opt/puppetlabs/bin/r10k'
    else
      R10KBIN=$(find /opt/puppetlabs -type f -name r10k | sort | head -n1)
      if [ -z "$R10KBIN" ];
      then
        if [ ! -e "$R10KBIN" ];
        then
          echo "r10k not found"
          exit 1
        fi
      fi
    fi
  fi
}


puppet_version_check()
{
  PUPPET_FULL_VERSION=$($PUPPETBIN --version 2>/dev/null)

  if [ "$?" -ne 0 ];
  then
    echo "unexpected puppet error"
  fi

  PUPPET_MAJOR_VERSION=$($PUPPETBIN --version | grep -Eo "^[0-9]")

  if [ "$PUPPET_MAJOR_VERSION" -lt "3" ];
  then
    echo "please install at least 3.8"
    exit 1
  fi

  PUPPET_MINOR_VERSION=$($PUPPETBIN --version | grep -Eo "\.[0-9]*\." | cut -f2 -d.)

  if [ "$PUPPET_MAJOR_VERSION" -eq "3" ] && [ "$PUPPET_MINOR_VERSION" -lt "8" ];
  then
    echo "please install at least 3.8"
    exit 1
  fi

  #PUPPET_OPTIONS
  if [ "$PUPPET_MAJOR_VERSION" -eq "3" ];
  then
    PUPPET_OPTIONS="${PUPPET_OPTIONS} --pluginsync"
  fi
}

puppet_apply()
{
  $PUPPETBIN apply --modulepath=$DIR/modules $PUPPET_OPTIONS $SITEPP $HIERAYAML_OPT 2>&1

  EXIT_CODE_PUPPET=$?
}

PUPPET_RUN_TIMES="1"
SLEEP_TIME_DEAMON="30m"

while getopts 't:r:p:s:d:y:hlpfvb:DT:S:' OPT; do
  case $OPT in
    d)  DIR=$OPTARG;;
    D)  DAEMON_MODE="y";;
    S)  SLEEP_TIME_DEAMON=$OPTARG;;
    T)  PUPPET_RUN_TIMES=$OPTARG;;
    s)  SITEPP=$OPTARG;;
    y)  HIERAYAML=$OPTARG;;
    b)  PUPPETBUILD=$OPTARG;;
    l)  MODULELIST=1;;
    p)  PUPPETFILE=$OPTARG;;
    r)  GITREPO=$OPTARG;;
    t)  GITREPO_TAG=$OPTARG;;
    v)  PUPPET_OPTIONS="${PUPPET_OPTIONS} --debug";;
    f)  FACTS="yes";;
    h)  JELP="yes";;
    *)  JELP="yes";;
  esac
done

if ! [[ ${PUPPET_RUN_TIMES} =~ ^[0-9]+$ ]];
then
   echo "ERROR: -T option is not a number" >&2
   exit 1
fi

if [ ! -z "$HIERAYAML" ];
then
	HIERAYAML_OPT="--hiera_config $HIERAYAML"
fi

shift $(($OPTIND - 1))

# usage
HELP="
    usage: $0 -d <localpuppetmaster dir> [ [-D] [-p <Puppetfile> ] [-l] [-b <puppet module dir>] | [-s site.pp] [-y hiera.yaml] [<tar to install> [module to install] | <module to install from puppetforge>] ]
    syntax:
            -d : puppetmaster directory
            -s : site.pp to apply
            -y : hiera.yaml
            -l : show installed puppet modules
            -p : Puppetfile to use
            -r : git repo to install
            -t : git repo tag
            -b : build puppet module
            -h : print this help screen
            -D : daemon mode
            -v : enable debug mode
            -T : in agent mode, how many times puppet agent will be applied
            -S : sleep time for daemon mode
"

if [ "$JELP" = "yes" ]; then
  echo "$HELP"
  exit 1
fi

if [ -z "$DIR" ];
then
  DIR_AUTOGENERATED=1
  DIR=$(mktemp /tmp/bundle.XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX)
  rm $DIR
  mkdir $DIR
else
  DIR_AUTOGENERATED=0
fi

# transform relative path to absolute
case $DIR in
  /*) true ;;
  *) DIR="$(pwd)/${DIR}" ;;
esac

if [ -z "$1" ];
then
  APPLY_ONLY=1
  unpack_bundle
else
  APPLY_ONLY=0
  if [ -f $1 ];
  then
    INSTALL_FROM_FORGE=0
  else
    echo $1 | grep -Eo '[a-zA-Z0-9]+-[a-zA-Z0-9]+'
    if [ "$?" -eq 0 ];
    then
      INSTALL_FROM_FORGE=1
    else
      echo "neither a valid puppet module nor a tarball not found"
      echo "$HELP"
      exit 1
    fi
  fi
fi

if [ -z "$DIR" ];
then
  echo "localpuppetmaster dir not defined"
  echo "$HELP"
  exit 1
fi

puppet_check

puppet_version_check

mkdir -p $DIR/pkg
mkdir -p $DIR/modules

if [ ! -z "${PUPPETFILE}" ] && [ ! -e "${PUPPETFILE}" ];
then
  echo "Puppetfile not found: ${PUPPETFILE}"
  exit 1
fi

if [ ! -z "$HIERAYAML" ];
then
  if [ ! -e $HIERAYAML ];
  then
    echo "$HIERAYAML does not exists"
    exit 1
  fi
  HIERA_PUPPET_OPT=" --hiera_config $HIERAYAML "
fi

if [ ! -z "${PUPPETBUILD}" ];
then
  PATH_BUILT_TAR_FILE=$($PUPPETBIN module build $PUPPETBUILD 2>/dev/null | grep "^Module built" | sed 's/^Module built: //g')
  $PUPPETBIN module install "${PATH_BUILT_TAR_FILE}"
fi

if [ ! -z "${PUPPETFILE}" ] || [ ! -z "${GITREPO}" ];
then
  r10k_check

  ANTERIOR_CWD="$(pwd)"
  cd ${DIR}

  echo "moduledir '${DIR}/modules'" > ${DIR}/Puppetfile

  if [ ! -z "${PUPPETFILE}" ];
  then
    grep -v "^moduledir" ${PUPPETFILE} >> ${DIR}/Puppetfile
  fi

  if [ ! -z "${GITREPO}" ];
  then
    MODULE_NAME_FROM_GITREPO="$(echo "${GITREPO}" | rev | cut -f1 -d/ | rev | cut -f1 -d. | rev | cut -f1 -d- | rev)"
    echo "mod '${MODULE_NAME_FROM_GITREPO}'," >> ${DIR}/Puppetfile
    echo -n "  :git => '${GITREPO}'" >> ${DIR}/Puppetfile
    if [ ! -z "${GITREPO_TAG}" ];
    then
      echo -e ",\n  :tag => '${GITREPO_TAG}'" >> ${DIR}/Puppetfile
    else
      echo ""
    fi
  fi

  echo "Checking Puppetfile syntax:"
  $R10KBIN puppetfile check
  if [ "$?" -ne 0 ];
  then
    echo "Puppetfile syntax error, exiting"
    exit 1
  fi

  if [ ! -z "${GITREPO}" ] && [ -d "${DIR}/modules/${MODULE_NAME_FROM_GITREPO}" ];
  then
    echo "Cleanup ${MODULE_NAME_FROM_GITREPO} module"
    FULL_MODULE_NAME=$($PUPPETBIN module list --modulepath=${DIR}/modules | grep -Eo "[a-z0-9A-Z]*-${MODULE_NAME_FROM_GITREPO}\b")
    $PUPPETBIN module uninstall ${FULL_MODULE_NAME} --modulepath=${DIR}/modules --force
  fi


  echo "Installing puppet module using a Puppetfile"
  $R10KBIN puppetfile install
  if [ "$?" -ne 0 ];
  then
    echo "r10k failed to install modules, exiting"
    exit 1
  fi

  echo "Installing dependencies"
  # instala dependencies
  for i in $($PUPPETBIN module list --modulepath=${DIR}/modules 2>&1 | grep "Warning: Missing dependency" | cut -f2 -d\' | sort -k2 -t-);
  do
    INSTALL_OUTPUT=$($PUPPETBIN module install $i --modulepath=${DIR}/modules 2>&1)
    $PUPPETBIN module list --modulepath=${DIR}/modules 2>/dev/null | grep $i >/dev/null 2>&1
    if [ $? -ne 0 ];
    then
      echo "ERROR installing dependencies"
      echo $INSTALL_OUTPUT
      exit 1
    fi
  done
  echo "Dependencies installed"

  cd "${ANTERIOR_CWD}" # cd -
fi

if [ "$MODULELIST" == "1" ];
then
  $PUPPETBIN module --modulepath=$DIR/modules list
  exit $?
fi

if [ "$APPLY_ONLY" -eq 0 ];
then
  if [ "$INSTALL_FROM_FORGE" -eq 0 ];
  then
    tarball_install $@
  else
    forge_install $@
  fi
fi

if [ ! -z "$SITEPP" ];
then
  if [ -z "${DAEMON_MODE}" ];
  then
    for i in $(seq 1 ${PUPPET_RUN_TIMES});
    do
      puppet_apply
    done
  else
    while true;
    do
      puppet_apply
      sleep ${SLEEP_TIME_DEAMON}
    done
  fi
fi

if [ ! -z "$FACTS" ];
then
  $PUPPETBIN facts --modulepath=$DIR/modules $PUPPET_OPTIONS $HIERAYAML_OPT 2>&1
fi

# if [ "$DIR_AUTOGENERATED" -eq 1 ];
# then
#   rm -fr $DIR
# fi

exit $EXIT_CODE_PUPPET
__AQUI_BUNDLE_TGZ__
