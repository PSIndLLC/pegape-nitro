#!/bin/sh
# Invoke this script as follows after downloading PegaPE :
# # install.sh 116329_PE8.2.1.zip

function scriptextract {
    printf "Extracting script %s from %s\n" ${2} ${1}
    tagln=\#\#\#\ $2
    [ -f $2 ] && echo "Removing current file $2" && rm $2
    unset doextract
    while IFS= read -r line; do
	if [ "z$line" = "z$tagln" ] ; then
	    if [ -z ${doextract+x} ] ; then doextract=true
	    else unset doextract
	    fi
	else
	    [ "${doextract+x}" = "x" ] && printf "%s\n" "$line" >> $2
	fi
    done < $1
}

function installlinux {
    if [ -z ${APP_INST+x} ] ; then
	export APP_INST=`which dnf 2>/dev/null`
	[ "Z${APP_INST}" = "Z" ] && export APP_INST=`which yum 2>/dev/null`
	if [ "Z${APP_INST}" = "Z" ] ; then
            export APP_INST=`which apt-get 2>/dev/null`
            export CHK_INST_ARGS=-l
        else
            export CHK_INST_ARGS=list\ installed
        fi
	echo "APP_INST identified as ${APP_INST}"
    fi
    [ ! "Z${APP_INST}" = "Z" ] && ${APP_INST} ${CHK_INST_ARGS} $1 # 1>/dev/null 2>&1
    if [ $? -gt 0 ] ; then
        echo "Installing $1 with ${APP_INST}..."
        [ ! "Z${APP_INST}" = "Z" ] && sudo ${APP_INST} install $1
    fi
}

function envinit {
    export MVEXEC=`which mv`
    export OS_TYPE=`uname`
    export NUMBER_OF_PROCESSORS=`getconf _NPROCESSORS_ONLN`
    export PE_PKG_DIR=`pwd`
    export PE_UID=${USER}
    
    export PATCHEXEC=`which patch 2>/dev/null`
    echo "Setting up environment : ${OS_TYPE} : ${PATCHEXEC} p utility"
    ( [ "Z${PATCHEXEC}" = "Z" ] && [ "${OS_TYPE}" = "Linux" ] ) && installlinux patch
    export PATCHEXEC=`which patch 2>/dev/null`
    [ "Z${PATCHEXEC}" = "Z" ] && echo "patch utility (${PATCHEXEC}) not available - abort install" && exit 2

    if [ "$OS_TYPE" = "Linux" ] ; then
	if [ -d /usr/java ] ; then
	    export JAVA_SEARCH=/usr/java
	else
	    export JAVA_SEARCH=/usr/lib
	fi
	export PG_SEARCH=/usr
    else
	export JAVA_SEARCH=/Library/Java/JavaVirtualMachines
	export PG_SEARCH=/Library/PostgreSQL
    fi
    unset APP_INST
}

function installjava {
    # Find last installed version of Java
    unset JRE_HOME
    for j in `find ${JAVA_SEARCH} -name javac | xargs -I foo dirname foo | xargs -I foo dirname foo` ; do
	( [ -z ${JRE_HOME+x} ] || [ $j -nt ${JRE_HOME} ] ) && export JRE_HOME=$j ;
    done
    
    # For Linux - if Java not installed, try to install
    if [ -z ${JRE_HOME+x} ] ; then
        if [ "${OS_TYPE}" = "Linux" ] ; then
	    read -p "Version of Pega prior to 7.2 require manual installation of a JDK from Oracle. Enter the value N to abort and install the JVM manually, or any other  key to continue: " JVM_MAN_INSTALL
	    [ "Z${JVM_MAN_INSTALL}" = "ZN" ] && exit 6
	    installlinux java-1.8.0-openjdk
	    installlinux java-1.8.0-openjdk-devel
	    for j in `find ${JAVA_SEARCH} -name javac | xargs -I foo dirname foo | xargs -I foo dirname foo` ; do
		( [ -z ${JRE_HOME+x} ] || [ $j -nt ${JRE_HOME} ] ) && export JRE_HOME=$j ;
	    done
        fi
    fi 
}

function installdmg {
    set -x
    tempd=$(mktemp -d)
    curl $1 > $tempd/pkg.dmg
    listing=$(sudo hdiutil attach $tempd/pkg.dmg | grep Volumes)
    volume=$(echo "$listing" | cut -f 3)
    if [ -e "$volume"/*.app ]; then
      sudo cp -rf "$volume"/*.app /Applications
    elif [ -e "$volume"/*.pkg ]; then
      package=$(ls -1 "$volume" | grep .pkg | head -1)
      sudo installer -pkg "$volume"/"$package" -target /
    fi
    sudo hdiutil detach "$(echo "$listing" | cut -f 1)"
    rm -rf $tempd
    set +x
}

function buildpljava {
    set -x
    PLJAVA_CTRL=`find ${PGBASEPATH}/share -name pljava.control`
    if ( [ "Z${PLJAVA_CTRL}" = "Z" ] || [ ! -f ${PLJAVA_CTRL} ] ) ; then
        tempd=$(mktemp -d)
        pushd $tempd
        # See http://tada.github.io/pljava/install/install.html
        installlinux gcc-c++
        installlinux postgresql94-devel
        [ $? -gt 0 ] && installlinux postgresql-devel
        installlinux openssl-devel
        installlinux maven
        installlinux maven-surefire-plugin
        git clone https://github.com/tada/pljava.git pljava
        echo "pljava project cloned locally... building version 1_5_2"
        pushd pljava
        git checkout tags/V1_5_2
        # TODO Add surefire plugin version to pom.xml to ensure maven build
        MVNSRFR_VER=`yum info maven-surefire-plugin | grep Version | cut -f 2 -d ':' | cut -c2-`
        #[ -f ${PE_PKG_DIR}/pom.xml ] && mv pom.xml pom.xml.orig&& cp ${PE_PKG_DIR}/pom.xml .
        [ -f ${PE_PKG_DIR}/pom.xml.patch ] && ${PATCHEXEC} -p0 < ${PE_PKG_DIR}/pom.xml.patch
        sed -e 's/MVNSRFR_VER/'$MVNSRFR_VER'/g' -i.orig pom.xml
        mvn clean install
        popd
        [ -d pljava/pljava-packaging/target ] && PLJINSTJAR=`find pljava/pljava-packaging/target -name pljava-\*\.jar`
	echo "Running PLJava jar for installation to PostgreSQL"
        sudo java -jar $PLJINSTJAR;
	JRE_NTV_SRV_PATH=`find ${JAVA_HOME}/jre/lib -type d -name server 2>/dev/null`
	if [ ! "Z${JRE_NTV_SRV_PATH}" = "Z" ] ; then
	    export LD_LIBRARY_PATH="$LD_LIBRARY_PATH${LD_LIBRARY_PATH+:}${JRE_NTV_SRV_PATH}"
	    if [ -d /etc/ld.so.conf.d ] ; then
		echo "${JRE_NTV_SRV_PATH}" > pljava.conf
		sudo mv pljava.conf /etc/ld.so.conf.d/
		sudo ldconfig
	    fi
	fi
        popd
        rm -rf $tempd
	sleep 2
    else
        echo "PLJava control file found - additional configuration not required"
    fi
    set +x
}

function preppostgresql {
    # Set PostgreSQL environment variables & start PostgreSQL
    [ -f pg_env.sh ] && . ./pg_env.sh
    if [ "$OS_TYPE" = "Linux" ] ; then 
        if [ "Z${PGBASEPATH}" = "Z" ] ; then
            # Try install of postgresql94 - then try general postgresql
	    #installlinux postgresql94
	    #[ $? -gt 0 ] && installlinux postgresql
	    installlinux postgresql94-server
	    [ $? -gt 0 ] && installlinux postgresql-server
	fi
	# Allow any user to write to postgresql run directory for pid files
	echo "Allow all access to /var/run/postgresql for any user"
	[ ! -d /var/run/postgresql ] && sudo mkdir /var/run/postgresql
	[ -d /var/run/postgresql ] && sudo chmod 777 /var/run/postgresql
    else
        # Assume this is MacOSX / Darwin
	if [ ! -d ${PG_SEARCH} ] ; then
	    # Download and install version 9.4 includes pljava
            PGDMGURL="https://sbp.enterprisedb.com/getfile.jsp?fileid=11986&_ga=2.9748854.2102799494.1568212746-660010164.1568212746"
            installdmg ${PGDMGURL}
            open postgresql-9.4.24-1-osx
	fi
        # Link google-chrome on MacOSX - ensure browser referenced in prdeploy.jar can be found
	if ( [ -d /Applications/Google\ Chrome.app/Contents/MacOS ] &&
	     [ ! -h /Applications/Google\ Chrome.app/Contents/MacOS/google-chrome ] ); then
            pushd /Applications/Google\ Chrome.app/Contents/MacOS
	    echo "Creating link to google-chrome from MacOS application"
            sudo ln -s Google\ Chrome google-chrome
            popd
            export PATH=$PATH:/Applications/Google\ Chrome.app/Contents/MacOS
	fi
    fi
    echo "PG Search path is ${PG_SEARCH}"
    unset PGBASEPATH; for p in `find ${PG_SEARCH} -name pg_ctl 2>/dev/null | xargs -I foo dirname foo | xargs -I foo dirname foo` ; do ( [ -z ${PGBASEPATH+x} ] || [ $p -nt ${PGBASEPATH} ] ) && export PGBASEPATH=$p ; echo "considered path $p for PostgreSQL"; done
    echo "PostgreSQL base path is ${PGBASEPATH}:${OS_TYPE} ... consider building pljava"
    [ ! -z ${PGBASEPATH+x} ] && [ "${OS_TYPE}" = "Linux" ] && buildpljava
}

function show_help
{
    CORP_GROUPS=`getent group | grep \:60 | grep -v \  | cut -f 1 -d ':' | sed -e 's/\(.*\)/                           \1/g'`
    printf "Usage: $0 <options> <pega_pe_install_file>
Options are as follows:
 Mandatory:
  Must pass the Pega PE install file as the last argument on the command line
 Optional:
  -i                  Presence indicates script should run interactively
  -U <uid>            Specify the uid to own and launch the installation
  -q                  Run in quiet mode
  -v                  Run in verbose mode
  -h                  Show utility help\n\n
The final argument on the command line must be the uid\n\n" "${CORP_GROUPS}"

}

# Determine environment - OS type, search paths, CPU count
envinit

# Read CL arguments - override PE_UID if passed
while getopts "h?c:iMn:N:U:" opt; do
    case "$opt" in
    h)
        show_help
        exit 0
        ;;
    i)
        IS_INTERACTIVE=true
        ;;
    U|\?)
	PE_UID=$OPTARG
        ;;
    q)  VERBOSE=-1
        ;;
    v)  VERBOSE=1
        ;;
    esac
done

shift $((OPTIND-1))

if [ "${IS_INTERACTIVE}" == "true" ] ; then 
    read -p "Enter pega runtime user uid: " PE_UID
else
    echo "Effective runtime user will be $PE_UID"
    sleep 3
fi

# Extract scripts and patch file
#scriptextract $0 startup.sh
#chmod a+x startup.sh
scriptextract $0 pg_env.sh
chmod u+x pg_env.sh
scriptextract $0 pom.xml.patch
scriptextract $0 installPLJavaExtension.sql
scriptextract $0 nitro.patch

# Find JRE HOME & setup Java environment - abort if java is not installed
installjava
if [ ! -z "${JRE_HOME+x}" ] ; then
    echo Java home found at ${JRE_HOME} 
    export JAVA_HOME=${JRE_HOME}
    [ -d ${JRE_HOME}/bin/server ] && export PATH=${JRE_HOME}/bin/server:${PATH}
    [ -d ${JRE_HOME}/bin ] && export PATH=${JRE_HOME}/bin:${PATH}
else
    echo Java home was not found, install Java 8 manually and retry PegaPE installation
    exit 1
fi

# Ensure PostgreSQL / pljava is installed
preppostgresql

# Run ant installer - do text install if DISPLAY is unset
[ ! "Z$1" = "Z" ] && "${JAVA_HOME}/bin/jar" xvf $1 && rm -rf jdk*
jar xvf PRPC_PE.jar build.xml antinstall-config.xml

[ -f nitro.patch ] && ${PATCHEXEC} -p0 < nitro.patch 
${MVEXEC} build.xml build-nitro.xml 
${MVEXEC} antinstall-config.xml antinstall-config-nitro.xml

export INSTALL_MODE=text
if [ -z ${DISPLAY+x} ] ; then
    sed -e 's/.*portavailabilitybutton.*//g' -i.gui antinstall-config-nitro.xml
else
    unset INSTALL_MODE
fi

jar uvf PRPC_PE.jar build-nitro.xml antinstall-config-nitro.xml installPLJavaExtension.sql
if [ $? -gt 1 ] ; then
    echo "Failed to add antinstall-config-nitro.xml and build-nitro.xml to PRPC_PE.jar - manual rebuild of jar required to include the nitro configuration"
    exit 5
fi

# Switch user if specified . Exit if root user - non-root user required to run and configure database. 
if [ "$PE_UID" = "root" ] ; then
    echo "Install as root not permitted. Postgres requires non-root user to init."
    echo "Specify user with -U - user will be created if one does not exist"
    exit 2
else
    getent passwd $PE_UID > /dev/null 2>&1
    if [ $? -gt 0 ] ; then
	read -p "Specified user ${PE_UID} does not exist. Create user (Y/N) ?" NEW_USER
	if [ "${NEW_USER}" = "Y" ] ; then
	    useradd --system -N -m -d /usr/local/PegaPE -s /sbin/nologin -G postgres ${PE_UID}
	    if [ $? -gt 0 ] ; then
		echo "Failed to create user ${PE_USER}, aborting install"
		exit 3
	    fi
	else
	    echo "Aborting setup absent user existance"
	    exit 4
	fi
    fi
fi

# Ensure install directory exists and is owned by the runtime user
[ ! -d /usr/local/PegaPE ] && mkdir -p /usr/local/PegaPE
chown -R $PE_UID /usr/local/PegaPE .

if [ "$PE_UID" = "$USER" ] ; then
    "${JAVA_HOME}/bin/java" -Xms512M -Xmx1024M -jar PRPC_PE.jar ${INSTALL_MODE} -type nitro
else
    sudo -u $PE_UID --preserve-env=JAVA_HOME,PG_DATA,INSTALL_MODE,NUMBER_OF_PROCESSORS,PATH "${JAVA_HOME}/bin/java" -Xms512M -Xmx1024M -jar PRPC_PE.jar ${INSTALL_MODE} -type nitro
fi

rm -rf /usr/local/PegaPE/PRPCPersonalEdition/pgsql /usr/local/PegaPE/PRPCPersonalEdition/jre*
#TODO
#rm pg_env.sh nitro.patch build-nitro.xml antinstall-config-nitro.xml pom.xml.patch installPLJavaExtension.sql

exit 0



### installPLJavaExtension.sql
CREATE EXTENSION pljava;
GRANT USAGE ON LANGUAGE java TO pega;
### installPLJavaExtension.sql

### pg_env.sh
#!/bin/sh
# The script sets environment variables helpful for PostgreSQL
unset PGBASEPATH
for p in `find /Library/PostgreSQL -name pg_ctl 2>/dev/null | grep pg_ctl | xargs -I foo dirname foo | xargs -I foo dirname foo` ; do
    ( [ -z ${PGBASEPATH+x} ] || [ $p -nt ${PGBASEPATH} ] ) && export PGBASEPATH=$p 
done
[ -z ${PGBASEPATH+x} ] && [ -d /var/lib/pgsql ] && export PGBASEPATH=/usr
echo PostgreSQL home ${PGBASEPATH+found at} ${PGBASEPATH} 
export PGDATA=@PGDATA
export PLJAVAJAR=`find ${PGBASEPATH} -name pljava\*.jar 2>/dev/null | grep -v api | grep -v examples`
export PATH="${PGBASEPATH}/bin":${PATH}
export PGDATABASE=postgres
export PGUSER=postgres
export PGPASSWORD=postgres
export PGPORT=@PG_PORT
#export PGLOCALEDIR=${PGBASEPATH}\share\locale
[ ! "Z${PLJAVAJAR+}" = "Z" ] && [ -f ${PLJAVAJAR} ] && export CLASSPATH=${CLASSPATH}:${PLJAVAJAR}
### pg_env.sh

### startup.sh
#!/bin/sh
export CURRDIR=`dirname $0`

# Set Java environment variables
[ -f ${CURRDIR}/java_env.sh ] && . ${CURRDIR}/java_env.sh

# Set PostgreSQL environment variables & start PostgreSQL
[ -f ${CURRDIR}/pg_env.sh ] && . ${CURRDIR}/pg_env.sh
"${PGBASEPATH}/bin/pg_ctl" start -w -D "${PGDATA}" -l "${PGDATA}/PostgresLog.log"

# Start tomcat - continue after success - needs log line after "startup completed"
export CATALINA_HOME=/usr/local/PegaPE/PRPCPersonalEdition/tomcat
# Ensure DB connection schema is correct
sed -e 's/\(jdbc:postgresql:\/\/localhost:[0-9]*\/\)\(.*\)\"/\1'${PGDATABASE}'\"/g' -i.bk ${CATALINA_HOME}/conf/context.xml
echo "JRE_HOME=${JAVA_HOME}" > ${CATALINA_HOME}/bin/setenv.sh
echo "JAVA_OPTS=-Xms1024m -Xmx4096m -XX:PermSize=64m -XX:MaxPermSize=384m
sh "${CATALINA_HOME}/bin/startup.sh"
#( tail -f -n0 ${CATALINA_HOME}/logs/PegaRULES.log & ) | grep -q "startup completed"

# Locate chrome and start browse to local server if DISPLAY available
if [ ${DISPLAY+x} = x ] ; then
    export BROWSECMD=`which google-chrome`
    [ -z ${BROWSECMD+x} ] && for c in /Applications/Google\ Chrome.app /usr ; do [ -z ${BROWSECMD+x} ] && [ -d "$c" ] && export BROWSECMD=`find "$c" -name google-chrome`; done
    [ ${BROWSECMD+x} = x ] && "${BROWSECMD}" http://localhost:8080/prweb/PRServlet &
fi
echo "Ready for empathetic digital transformation !!!"
### startup.sh

# Create patch file section using commands:
# # diff -u build.xml build-nitro.xml > nitro.patch
# # diff -u antinstall-config.xml antinstall-config-nitro.xml >> nitro.patch
### nitro.patch
--- build.xml	2015-06-04 07:33:12.000000000 -0400
+++ build-nitro.xml	2019-11-29 17:18:45.273124490 -0500
@@ -2,7 +2,7 @@
 <project name="Installation Build"  default="Install"  xmlns:pega="pega:/pega.com">
 
 	<!-- this is required to pick up the properties generated during the install pages -->
-	<property file="${basedir}/ant.install.properties"/>
+	<property file="${basedir}${file.separator}ant.install.properties"/>
 
 	<!-- provides access to environmental variables -->
 	<property environment="env"/>
@@ -10,19 +10,71 @@
 	<!-- sets the version of PRPC this Personal Edition is built on -->
 	<property name="prpc.version" value="718" />
 	
+	<property name="db.name" value="postgres" />
+	<condition property="postgres.install.dir" value="${install.path}${file.separator}pgsql">
+	    <os family="windows"/>
+	</condition>
+	<condition property="postgres.install.dir" value="${file.separator}Library${file.separator}PostgreSQL${file.separator}9.4">
+	    <os family="mac"/>
+	</condition>
+	<condition property="postgres.install.dir" value="${file.separator}usr">
+	    <os family="unix"/>
+	</condition>
+
+	<condition property="postgres.install.libjvmdir" value="bin${file.separator}server${file.separator}jvm.dll">
+	    <os family="windows"/>
+	</condition>
+	<condition property="postgres.install.libjvmdir" value="jre${file.separator}lib${file.separator}jli${file.separator}libjli.dylib">
+	    <os family="mac"/>
+	</condition>
+	<condition property="postgres.install.libjvmdir" value="jre${file.separator}lib${file.separator}amd64${file.separator}server${file.separator}libjvm.so">
+	    <os family="unix"/>
+	</condition>
+
+	<condition property="postgres.install.libjvmext" value="dll">
+	    <os family="windows"/>
+	</condition>
+	<condition property="postgres.install.libjvmext" value="dylib">
+	    <os family="mac"/>
+	</condition>
+	<condition property="postgres.install.libjvmext" value="so">
+	    <os family="unix"/>
+	</condition>
+
+	<!-- Download MacOS PostgreSQL database package -->
+	<macrodef name="INSTALLDB">
+		<attribute name="binDir" default="${postgres.install.dir}${file.separator}bin"/>
+		<attribute name="dataDir" default="${postgres.data.dir}"/>
+		<attribute name="superUser" default="pega"/>
+		<sequential>
+			<exec executable="@{binDir}${file.separator}initdb" >
+				<arg value="-E"/>
+				<arg value="UTF-8"/>
+				<arg value="-D"/>
+				<arg value="@{dataDir}"/>
+				<arg value="-U"/>
+				<arg value="@{superUser}"/>
+				<env key="PGPORT" value="${pe.db.port}"/>
+				<env key="Path" value="${env.JAVA_HOME}${file.separator}bin:${env.JAVA_HOME}${file.separator}bin${file.separator}server:${env.Path}"/>
+			</exec>
+		</sequential>
+	</macrodef>
+
 	<!-- initialize the postgres data directory -->
 	<macrodef name="INITDB">
-		<attribute name="binDir" default="${postgres.install.dir}\bin"/>
-		<attribute name="dataDir" default="${postgres.install.dir}\data"/>
+		<attribute name="binDir" default="${postgres.install.dir}${file.separator}bin"/>
+		<attribute name="dataDir" default="${postgres.data.dir}"/>
 		<attribute name="superUser" default="pega"/>
 		<sequential>
-			<exec executable="@{binDir}\initdb" >
+			<exec executable="@{binDir}${file.separator}initdb" >
+                                <arg value="-E"/>
+                                <arg value="UTF-8"/>
 				<arg value="-D"/>
 				<arg value="@{dataDir}"/>
 				<arg value="-U"/>
 				<arg value="@{superUser}"/>
 				<env key="PGPORT" value="${pe.db.port}"/>
-				<env key="Path" value="${install.path}/jre1.7.0_71/bin;${install.path}/jre1.7.0_71/bin/server;${env.Path}"/>
+				<env key="Path" value="${env.JAVA_HOME}${file.separator}bin:${env.JAVA_HOME}${file.separator}bin${file.separator}server:${env.Path}"/>
 			</exec>
 		</sequential>
 	</macrodef>
@@ -30,18 +82,20 @@
 	<!-- Control the postgres server -->
 	<macrodef name="PGCTL">
 		<attribute name="command" default="start"/>
-		<attribute name="binDir" default="${postgres.install.dir}\bin"/>
-		<attribute name="dataDir" default="${postgres.install.dir}\data"/>
+		<attribute name="binDir" default="${postgres.install.dir}${file.separator}bin"/>
+		<attribute name="dataDir" default="${postgres.data.dir}"/>
 		<sequential>
-			<exec executable="@{binDir}\pg_ctl" spawn="true">
+			<exec executable="@{binDir}${file.separator}pg_ctl" dir="${postgres.install.dir}">
+				<arg value="-w"/>
+				<arg value="-s"/>
 				<arg value="-D"/>
 				<arg value="@{dataDir}"/>
 				<arg value="-l"/>
-				<arg value="@{dataDir}\pg.log"/>
+				<arg value="@{dataDir}${file.separator}pg.log"/>
 				<arg value="@{command}"/>
 				<env key="PGPORT" value="${pe.db.port}"/>
-				<env key="CLASSPATH" value="${postgres.install.dir}/lib/pljava.jar"/>
-				<env key="Path" value="${install.path}/jre1.7.0_71/bin;${install.path}/jre1.7.0_71/bin/server;${env.Path}"/>
+				<env key="CLASSPATH" value="${postgres.install.dir}${file.separator}share${file.separator}postgresql${file.separator}pljava-1.6.0-SNAPSHOT.jar"/>
+				<env key="Path" value="${env.JAVA_HOME}${file.separator}bin:${env.JAVA_HOME}${file.separator}bin${file.separator}server:${env.Path}"/>
 			</exec>
 		</sequential>
 	</macrodef>
@@ -50,29 +104,30 @@
 	<macrodef name="PSQL">
 		<attribute name="command"/>
 		<attribute name="flag" default="-c"/>
-		<attribute name="binDir" default="${postgres.install.dir}\bin"/>
+		<attribute name="binDir" default="${postgres.install.dir}${file.separator}bin"/>
 		<sequential>
-			<exec executable="@{binDir}\psql" failonerror="true">
+			<exec executable="@{binDir}${file.separator}psql" failonerror="true">
 					<arg value="@{flag}"/>
 					<arg value="@{command}"/>
-					<arg value="postgres"/>
+					<arg value="${db.name}"/>
 					<arg value="pega"/>
 					<env key="PGPORT" value="${pe.db.port}"/>
-					<env key="Path" value="${install.path}/jre1.7.0_71/bin;${install.path}/jre1.7.0_71/bin/server;${env.Path}"/>
+					<env key="Path" value="${env.JAVA_HOME}${file.separator}bin:${env.JAVA_HOME}${file.separator}bin${file.separator}server:${env.Path}"/>
 			</exec>
 		</sequential>
 	</macrodef>
 	
 	<!-- restore a dump to the postgres database -->
 	<macrodef name="PGRESTORE">
-			<attribute name="binDir" default="${postgres.install.dir}\bin"/>
-			<attribute name="dataDir" default="${postgres.install.dir}\data"/>
-			<attribute name="databaseName" default="pega"/>
+			<attribute name="binDir" default="${postgres.install.dir}${file.separator}bin"/>
+			<attribute name="dataDir" default="${postgres.data.dir}"/>
+			<attribute name="databaseName" default="${db.name}"/>
 			<attribute name="superUser" default="pega"/>
 			<attribute name="processes" default="2"/>
-			<attribute name="dumpfile" default="${user.dir}\data\pega.dump"/>
+			<attribute name="dumpfile" default="${user.dir}${file.separator}data${file.separator}pega.dump"/>
+                        <attribute name="failOnError" default="true" />
 			<sequential>
-				<exec executable="@{binDir}\pg_restore" failonerror="true">
+				<exec executable="@{binDir}${file.separator}pg_restore" failonerror="@{failOnError}">
 					<arg value="-U"/>
 					<arg value="@{superUser}"/>
 					<arg value="-d"/>
@@ -83,7 +138,7 @@
 					<arg value="-v"/>
 					<arg value="@{dumpfile}"/>
 					<env key="PGPORT" value="${pe.db.port}"/>
-					<env key="Path" value="${install.path}/jre1.7.0_71/bin;${install.path}/jre1.7.0_71/bin/server;${env.Path}"/>
+					<env key="Path" value="${env.JAVA_HOME}${file.separator}bin:${env.JAVA_HOME}${file.separator}bin${file.separator}server:${env.Path}"/>
 				</exec>
 			</sequential>
 	</macrodef>
@@ -92,7 +147,7 @@
 	<!-- Custom Tasks -->
 	<taskdef resource="com/pega/pegarules/util/anttasks/tasks.properties" uri="pega:/pega.com">
 		<classpath>
-			<pathelement location="${basedir}/prdeploy.jar"/>
+			<pathelement location="${basedir}${file.separator}prdeploy.jar"/>
 		</classpath>
 	</taskdef>
 
@@ -104,7 +159,7 @@
 									PRPC Launching"/>
 
 	<target name="Initialization">
-		<property name="install.path" location="${install.dir}/PRPCPersonalEdition"/>
+		<property name="install.path" location="${install.dir}${file.separator}PRPCPersonalEdition"/>
 		<property environment="env"/>
 		<echo message="Beginning installation of PRPC ${prpc.version} Personal Edition -- this process should take about 5-10 minutes ..."/>
 		<tstamp>
@@ -113,19 +168,19 @@
 
 		<!-- create the installation directory and temporary directory -->
 		<mkdir dir="${install.path}" />
-		<mkdir dir="${install.path}\temp"/>
+		<mkdir dir="${install.path}${file.separator}temp"/>
 		
 		<!-- extract the inner zip containing Tomcat, Java, Postgres and our scripts -->
 		<unzip src="PersonalEdition.zip" dest="${install.path}" />
 
 		<echo message="Configuring Tomcat (Setting Java Home and Catalina Home)..." />
-		<replace summary="true" dir="${install.path}/tomcat/bin" token="@CATALINA_HOME" value="${install.path}/tomcat" >
+		<replace summary="true" dir="${install.path}${file.separator}tomcat${file.separator}bin" token="@CATALINA_HOME" value="${install.path}${file.separator}tomcat" >
 			<include name="shutdown.bat"/>
 			<include name="startup.bat"/>
-		</replace>
-		<replace summary="true" file="${install.path}/tomcat/bin/setenv.bat" token="@JAVA_HOME" value="${install.path}\jre1.7.0_71" />
-		<replace summary="true" file="${install.path}/scripts/pg_env.bat" token="@JAVA_HOME" value="${install.path}\jre1.7.0_71" />
-		<replace summary="true" file="${install.path}\tomcat\conf\context.xml" token="@TEMP_DIR" value="${install.path}\temp" />
+		</replace>
+		<replace summary="true" file="${install.path}${file.separator}tomcat${file.separator}bin${file.separator}setenv.bat" token="@JAVA_HOME" value="${env.JAVA_HOME}" />
+		<replace summary="true" file="${install.path}${file.separator}scripts${file.separator}pg_env.bat" token="@JAVA_HOME" value="${env.JAVA_HOME}" />
+		<replace summary="true" file="${install.path}${file.separator}tomcat${file.separator}conf${file.separator}context.xml" token="@TEMP_DIR" value="${install.path}${file.separator}temp" />
 		
 		<!-- Number of processors will determine the number of processes to use in restoring data to the database -->
 		<property name="num.processors" value="${env.NUMBER_OF_PROCESSORS}"/>
@@ -136,21 +191,45 @@
 	<target name="Database Server Installation">
 		
 		<!-- set the directory postgres is installed to -->
-		<property name="postgres.install.dir" value="${install.path}/pgsql" />
+		<condition property="postgres.install.dir" value="${file.separator}Library${file.separator}PostgreSQL${file.separator}9.4">
+		  <os family="mac"/>
+		</condition>
+		<condition property="postgres.data.dir" value="${install.path}${file.separator}data">
+		  <os family="unix"/>
+		</condition>
+		<condition property="postgres.install.dir" value="${install.path}${file.separator}pgsql">
+		  <os family="windows"/>
+		</condition>
 				
 		<!-- initialize postgres data directory -->
-		<INITDB binDir="${postgres.install.dir}\bin" dataDir="${postgres.install.dir}\data" superUser="pega"/>
+		<INITDB binDir="${postgres.install.dir}${file.separator}bin" dataDir="${postgres.data.dir}" superUser="pega"/>
+
+		<!-- Set JVM location in configuration before starting DB -->
+		<property name="libjvm.location.setting" value="pljava.libjvm_location = '${env.JAVA_HOME}${file.separator}${postgres.install.libjvmdir}'"/>
+		
+		<!--
+		<loadresource property="libjvm.location.setting.cleaned">
+			<propertyresource name="libjvm.location.setting"/>
+			<filterchain>
+				<tokenfilter>
+					<replacestring from="\" to= "/" />
+				</tokenfilter>
+			</filterchain>
+		</loadresource>
+		-->
+		<property name="libjvm.location.setting.cleaned" value="${libjvm.location.setting}"/>
+		<echo file="${postgres.data.dir}${file.separator}postgresql.conf" message="${libjvm.location.setting.cleaned}" append="true"/>
 		
 		<!-- start the postgres service -->
-		<PGCTL command="start" binDir="${postgres.install.dir}\bin" dataDir="${postgres.install.dir}\data"/>
+		<PGCTL command="start" binDir="${postgres.install.dir}${file.separator}bin" dataDir="${postgres.data.dir}"/>
 		
 		<echo message=""/>		
 		<echo message="Waiting for Postgres to start..."/>
 		
 		<pega:isdbavailable 
-			driverpath="${install.path}\tomcat\lib\postgresql-9.2-1000.jdbc4.jar"
+			driverpath="${install.path}${file.separator}tomcat${file.separator}lib${file.separator}postgresql-9.2-1000.jdbc4.jar"
 			driverclass="org.postgresql.Driver"
-			url="jdbc:postgresql://localhost:${pe.db.port}/postgres"
+			url="jdbc:postgresql://localhost:${pe.db.port}/${db.name}"
 			user="pega"
 			pw="pega"
 			query="select current_database()"
@@ -160,22 +239,25 @@
 				      
 		
 		<!-- create database and user -->
-		<PSQL binDir="${postgres.install.dir}\bin" flag="-f" command="${install.path}\scripts\SetupDBandUser.sql"/>
+		<PSQL binDir="${postgres.install.dir}${file.separator}bin" flag="-f" command="${install.path}${file.separator}scripts${file.separator}SetupDBandUser.sql"/>
+
+ 		<!-- install pljava extensions -->
+		<PSQL binDir="${postgres.install.dir}${file.separator}bin" flag="-f" command="${basedir}${file.separator}installPLJavaExtension.sql"/>
 
 	</target>
 
 	<target name="Data Load">
 		
 		<!-- restart the postgres service -->
-		<PGCTL command="restart" binDir="${postgres.install.dir}\bin" dataDir="${postgres.install.dir}\data"/>
+		<PGCTL command="restart" binDir="${postgres.install.dir}${file.separator}bin" dataDir="${postgres.data.dir}"/>
 		
 		<echo message=""/>		
 		<echo message="Waiting for Postgres to restart..."/>
 		
 		<pega:isdbavailable 
-			driverpath="${install.path}\tomcat\lib\postgresql-9.2-1000.jdbc4.jar"
+			driverpath="${install.path}${file.separator}tomcat${file.separator}lib${file.separator}postgresql-9.2-1000.jdbc4.jar"
 			driverclass="org.postgresql.Driver"
-			url="jdbc:postgresql://localhost:${pe.db.port}/postgres"
+			url="jdbc:postgresql://localhost:${pe.db.port}/${db.name}"
 			user="pega"
 			pw="pega"
 			query="select current_database()"
@@ -188,22 +270,159 @@
 		<echo message="Loading database with PRPC..."/>
 		
 		<!-- Call pg_restore to restore the dump, number of processors determines the number of processes used for this task -->
-		<PGRESTORE processes="${num.processors}" dumpfile="${user.dir}\data\sqlj.dump"/>
-		<PGRESTORE processes="${num.processors}"/>
+		<property name="data.restore.dir" value="${user.dir}${file.separator}data" />
+		<PGRESTORE processes="${num.processors}" dumpfile="${data.restore.dir}${file.separator}sqlj.dump" failOnError="false"/>
+		<PGRESTORE processes="${num.processors}" failOnError="false"/>
+
+ 		<echo message="Reindexing postgres database..." />
+		<PSQL binDir="${postgres.install.dir}${file.separator}bin" command="REINDEX DATABASE ${db.name};"/>
 	</target>
 	
 	<target name="Assign Ports">
 		<!-- Set port numbers for appserver and database server in tomcat configuration files -->
-		<replace summary="true" file="${install.path}\tomcat\conf\server.xml" token="@TCHTTP" value="${pe.tomcat.port}" />
-		<replace summary="true" file="${install.path}\tomcat\conf\context.xml" token="@PG_PORT" value="${pe.db.port}" />
-		<replace summary="true" file="${install.path}\tomcat\bin\catalina.bat" token="@TCHTTP" value="${pe.tomcat.port}" />
+		<replace summary="true" file="${install.path}${file.separator}tomcat${file.separator}conf${file.separator}server.xml" token="@TCHTTP" value="${pe.tomcat.port}" />
+		<replace summary="true" file="${install.path}${file.separator}tomcat${file.separator}conf${file.separator}context.xml" token="@PG_PORT" value="${pe.db.port}" />
+		<replace summary="true" file="${install.path}${file.separator}tomcat${file.separator}bin${file.separator}catalina.bat" token="@TCHTTP" value="${pe.tomcat.port}" />
 		
 		<!-- Set port numbers for our Postgres environmental variable batch file -->
-		<replace summary="true" file="${install.path}\scripts\pg_env.bat" token="@PG_PORT" value="${pe.db.port}" />
+		<replace summary="true" file="${install.path}${file.separator}scripts${file.separator}pg_env.bat" token="@PG_PORT" value="${pe.db.port}" />
 	</target>
 
 	<target name="Configuration" depends="Assign Ports">
 
+		<!-- Java environment discovery script -->
+		<echo file="${install.path}${file.separator}scripts${file.separator}java_env.sh">#!/bin/sh
+# Find JRE HOME &amp; setup Java environment
+unset JRE_HOME ; for j in `find /Library/Java/JavaVirtualMachines -name Home 2>/dev/null` ; do ( [ -z $${JRE_HOME+x} ] || [ $$j -nt $${JRE_HOME} ] ) &amp;&amp; export JRE_HOME=$$j ; done 
+[ -z $${JRE_HOME+x} ] &amp;&amp; for j in `find /usr/lib -name javac | xargs dirname | xargs dirname` ; do ( [ -z $${JRE_HOME+x} ] || [ $$j -nt $${JRE_HOME} ] ) &amp;&amp; export JRE_HOME=$$j ; done
+JAVA_HOME=@JAVA_HOME
+[ ! -d $${JAVA_HOME}/jre ] &amp;&amp; export JAVA_HOME=$${JRE_HOME}
+echo JAVA_HOME set to $${JAVA_HOME} - JRE_HOME was found at $${JRE_HOME}
+export PATH=$${JRE_HOME}/bin:$${JRE_HOME}/bin/server:$${PATH}
+JRE_NTV_SVR_PATH=`find $${JAVA_HOME}/jre/lib -type d -name server 2>/dev/null`
+export LD_LIBRARY_PATH="$${LD_LIBRARY_PATH}$${LD_LIBRARY_PATH+:}$${JRE_NTV_SVR_PATH}"
+		</echo>
+		<replace summary="true" file="${install.path}${file.separator}scripts${file.separator}java_env.sh" token="@JAVA_HOME" value="${env.JAVA_HOME}" />
+
+		<!-- PostgreSQL environment discovery script -->
+		<echo file="${install.path}${file.separator}scripts${file.separator}pg_env.sh">#!/bin/sh
+# The script sets environment variables helpful for PostgreSQL
+unset PGBASEPATH
+for p in `find /Library/PostgreSQL -name pg_ctl 2>/dev/null | grep pg_ctl | xargs -I foo dirname foo | xargs -I foo dirname foo` ; do
+    ( [ -z $${PGBASEPATH+x} ] || [ $$p -nt $${PGBASEPATH} ] ) &amp;&amp; export PGBASEPATH=$$p 
+done
+[ -z $${PGBASEPATH+x} ] &amp;&amp; [ -d /var/lib/pgsql ] &amp;&amp; export PGBASEPATH=/usr
+echo PostgreSQL home $${PGBASEPATH+found at} $${PGBASEPATH} 
+export PGDATA=@PGDATA
+export PLJAVAJAR=`find $${PGBASEPATH}/share -name pljava\*.jar 2>/dev/null | grep -v api | grep -v examples`
+export PATH="$${PATH}$${PATH+:}$${PGBASEPATH}/bin"
+export PGDATABASE=@DB_NAME
+export PGUSER=pega
+export PGPASSWORD=pega
+export PGPORT=@PG_PORT
+#export PGLOCALEDIR=$${PGBASEPATH}/share/locale
+[ ! "Z$${PLJAVAJAR}" = "Z" ] &amp;&amp; [ -f $${PLJAVAJAR} ] &amp;&amp; export CLASSPATH=$${CLASSPATH}$${CLASSPATH+:}$${PLJAVAJAR}
+		</echo>
+		<replace summary="true" file="${install.path}${file.separator}scripts${file.separator}pg_env.sh" token="@PGDATA" value="${postgres.data.dir}" />
+		<replace summary="true" file="${install.path}${file.separator}scripts${file.separator}pg_env.sh" token="@PG_PORT" value="${pe.db.port}" />
+		<replace summary="true" file="${install.path}${file.separator}scripts${file.separator}pg_env.sh" token="@DB_NAME" value="${db.name}" />
+
+		<!-- Tomcat/Postgres Bash Startup -->
+		<echo file="${install.path}${file.separator}scripts${file.separator}startup.sh">#!/bin/sh
+export CURRDIR=`dirname $$0`
+
+# Set Java environment variables
+[ -f $${CURRDIR}/java_env.sh ] &amp;&amp; . $${CURRDIR}/java_env.sh
+
+# Set PostgreSQL environment variables &amp; start PostgreSQL if not running
+[ -f $${CURRDIR}/pg_env.sh ] &amp;&amp; . $${CURRDIR}/pg_env.sh
+"$${PGBASEPATH}/bin/pg_ctl" status -D "$${PGDATA}"
+[ $$? -gt 0 ] &amp;&amp; "$${PGBASEPATH}/bin/pg_ctl" start -w -D "$${PGDATA}" -l "$${PGDATA}/PostgresLog.log"
+
+# Start tomcat - continue after success - needs log line after "Server startup in"
+export CATALINA_HOME=@CATALINA_HOME
+# Ensure DB connection schema is correct
+sed -e 's/\(jdbc:postgresql:\/\/localhost:[0-9]*\/\)\(.*\)\"/\1'$${PGDATABASE}'\"/g' -i.bk $${CATALINA_HOME}/conf/context.xml
+echo "JRE_HOME=$${JAVA_HOME}" > $${CATALINA_HOME}/bin/setenv.sh
+echo "JAVA_OPTS=-Xms1024m -Xmx4096m -XX:PermSize=64m -XX:MaxPermSize=384m"  >> $${CATALINA_HOME}/bin/setenv.sh
+chmod 755 "$${CATALINA_HOME}/bin/catalina.sh" "$${CATALINA_HOME}/bin/setenv.sh"
+sh "$${CATALINA_HOME}/bin/startup.sh"
+( tail -f -n0 $${CATALINA_HOME}/logs/catalina.out &amp; ) | grep -q "Server startup in "
+
+# Locate chrome and start browse to local server if DISPLAY available
+if [ ! "Z$${DISPLAY}" = "Z" ] ; then
+    export BROWSECMD=`which google-chrome`
+    [ "Z$${BROWSECMD}" = "Z" ] &amp;&amp; for c in /Applications/Google\ Chrome.app /usr ; do
+	[ "Z$${BROWSECMD}" = "Z" ] &amp;&amp; [ -d "$$c" ] &amp;&amp; export BROWSECMD=`find "$$c" -name google-chrome 2>/dev/null`
+    done
+    [ ! "Z$${BROWSECMD}" = "Z" ] &amp;&amp; "$${BROWSECMD}" http://localhost:8080/prweb/PRServlet &amp;
+fi
+echo "Ready for empathetic digital transformation !!!"
+		</echo>
+
+		<echo file="${install.path}${file.separator}scripts${file.separator}shutdown.sh">#!/bin/sh
+export CURRDIR=`dirname $$0`
+
+# Set Java environment variables
+[ -f $${CURRDIR}/java_env.sh ] &amp;&amp; . $${CURRDIR}/java_env.sh
+
+# Start tomcat - continue after success
+export CATALINA_HOME=@CATALINA_HOME
+sh "$${CATALINA_HOME}/bin/shutdown.sh"
+( tail -f -n0 $${CATALINA_HOME}/logs/catalina.out &amp; ) | grep -q "logging shutdown complete"
+
+# Set PostgreSQL environment variables &amp; stop PostgreSQL
+[ -f $${CURRDIR}/pg_env.sh ] &amp;&amp; . $${CURRDIR}/pg_env.sh
+"$${PGBASEPATH}/bin/pg_ctl" stop -D "$${PGDATA}" -m immediate
+
+echo "Shutdown of PegaPE complete."
+		</echo>
+		<replace summary="true" dir="${install.path}${file.separator}scripts" token="@CATALINA_HOME" value="${install.path}${file.separator}tomcat" >
+			<include name="shutdown.sh"/>
+			<include name="startup.sh"/>
+		</replace>
+
+	      </target>
+
+	      <target name="OSX Shortcuts" depends="Configuration">
+
+		<!-- Tomcat/Postgres Startup Shortcut -->
+		<echo file="CreatePegaShortCut.sh">#!/bin/bash
+PEGAVERS=`echo ${prpc.version} | sed -e 's/\./_/g'`
+exec &amp;&gt;&gt; ~/Desktop/Start\ Pega\ $${PEGAVERS}
+printf "#!/bin/bash\n"
+printf "sh %s\n" "${install.path}${file.separator}scripts/startup.sh"
+exec &amp;&gt;&gt; /dev/null
+chmod 744 ~/Desktop/Start\ Pega\ $${PEGAVERS}
+		</echo>
+
+		<exec osfamily="unix" executable="bash">
+			<arg value="CreatePegaShortCut.sh" />
+		</exec>
+
+		<delete file="CreatePegaShortCut.sh" />
+
+		<!-- Tomcat/Postgres Shutdown Shortcut -->
+		<echo file="CreatePegaShortCut.sh">#!/bin/bash
+PEGAVERS=`echo ${prpc.version} | sed -e 's/\./_/g'`
+exec &amp;&gt;&gt; ~/Desktop/Stop\ Pega\ $${PEGAVERS}
+printf "#!/bin/bash\n"
+printf "sh %s\n" "${install.path}${file.separator}scripts/shutdown.sh"
+exec &amp;&gt;&gt; /dev/null
+chmod 744 ~/Desktop/Stop\ Pega\ $${PEGAVERS}
+		</echo>
+
+		<exec osfamily="unix" executable="bash">
+			<arg value="CreatePegaShortCut.sh" />
+		</exec>
+
+		<delete file="CreatePegaShortCut.sh" />
+		<!-- PRPC Login Screen Shortcut -->
+
+	</target>
+
+	<target name="Windows Shortcuts" depends="Assign Ports">
+
 		<!-- Tomcat/Postgres Startup Shortcut -->
 		<echo file="CreatePegaShortCut.vbs">
 			Set Shell = CreateObject("WScript.Shell")
@@ -212,15 +431,15 @@
 			' link.Arguments = "1 2 3"   'Arguments for shortcut executable
 			link.Description = "Start PRPC ${prpc.version}"
 			'  Fully qualified path (normally the executable) and an index associated with the icon 
-			link.IconLocation = "${install.path}\scripts\greenTriangle.ico,0"
-			link.TargetPath = "${install.path}\scripts\startup.bat"
+			link.IconLocation = "${install.path}${file.separator}scripts${file.separator}greenTriangle.ico,0"
+			link.TargetPath = "${install.path}${file.separator}scripts${file.separator}startup.bat"
 			' Activates and displays window [ 1 = normal | 3 = Maximized | 7 = Minimizes next to;-level window
 			link.WindowStyle = 1
-			link.WorkingDirectory = "${install.path}\scripts"
+			link.WorkingDirectory = "${install.path}${file.separator}scripts"
 			link.Save  
 		</echo>
 
-		<exec executable="cscript">
+		<exec osfamily="windows" executable="cscript">
 			<arg value="CreatePegaShortCut.vbs" />
 		</exec>
 
@@ -234,15 +453,15 @@
 			' link.Arguments = "1 2 3"   'Arguments for shortcut executable
 			link.Description = "Stop PRPC ${prpc.version}"
 			'  Fully qualified path (normally the executable) and an index associated with the icon 
-			link.IconLocation = "${install.path}\scripts\redSquare.ico,0"
-			link.TargetPath = "${install.path}\scripts\shutdown.bat"
+			link.IconLocation = "${install.path}${file.separator}scripts${file.separator}redSquare.ico,0"
+			link.TargetPath = "${install.path}${file.separator}scripts${file.separator}shutdown.bat"
 			' Activates and displays window [ 1 = normal | 3 = Maximized | 7 = Minimizes next to;-level window
 			link.WindowStyle = 1
-			link.WorkingDirectory = "${install.path}\scripts"
+			link.WorkingDirectory = "${install.path}${file.separator}scripts"
 			link.Save  
 		</echo>
 
-		<exec executable="cscript">
+		<exec osfamily="windows" executable="cscript">
 			<arg value="CreatePegaShortCut.vbs" />
 		</exec>
 
@@ -254,11 +473,12 @@
 			strDesktopPath = WshShell.SpecialFolders("Desktop")
 			Set objShortcutUrl = WshShell.CreateShortcut(strDesktopPath &amp; "\PRPC ${prpc.version} Login.lnk")
 			objShortcutUrl.TargetPath = "http://localhost:${pe.tomcat.port}/prweb/PRServlet"
-			objShortcutUrl.IconLocation = "${install.path}\scripts\pega.ico,0"
+			objShortcutUrl.IconLocation = "${install.path}${file.separator}scripts${file.separator}pega.ico,0"
+			objShortcutUrl.Description = "Log in to PRPC ${prpc.version}"
 			objShortcutUrl.Save 
 		</echo>
 
-		<exec executable="cscript">
+		<exec osfamily="windows" executable="cscript">
 			<arg value="CreatePegaShortCut.vbs" />
 		</exec>
 
@@ -268,15 +488,21 @@
 
 	<target name="PRPC Launching">
 		
-		<property name="tomcat.home" value="${install.path}/tomcat"/>
-		<property name="antRunAsync" value="ant_async/bin/antRunAsync.bat"/>
+		<property name="tomcat.home" value="${install.path}${file.separator}tomcat"/>
+		<property name="antRunAsync" value="ant_async${file.separator}bin${file.separator}antRunAsync.bat"/>
 		<echo message="Starting tomcat .... "/>
 		
 		<!-- start up tomcat asynchronously -->
-		<exec dir="${tomcat.home}/bin/" executable="${basedir}/${antRunAsync}"
+		<exec osfamily="windows" dir="${tomcat.home}${file.separator}bin${file.separator}" executable="${basedir}${file.separator}${antRunAsync}"
 			   vmlauncher="false" failonerror="true">
 			<arg value="startup" />
 		</exec>
+
+		<exec osfamily="unix" dir="${install.path}${file.separator}scripts" executable="${antRunAsync}" vmlauncher="false" failonerror="true">
+		        <env key="PATH" path="${env.PATH}:${basedir}${file.separator}bin"/>
+			<arg value="sh" />
+			<arg value="startup.sh" />
+		</exec>
 		
 		<echo message="Waiting for tomcat to start..."/>
 		
--- antinstall-config.xml	2015-06-04 07:33:10.000000000 -0400
+++ antinstall-config-nitro.xml	2019-11-28 19:00:00.409500048 -0500
@@ -45,12 +45,14 @@
 			name="PE-Overview"
 			displayText="PegaRULES Process Commander 718 Personal Edition - Installation"
 			splashResource="/resources/pega-grey-large.png"/>
+			altText="PegaRULES Process Commander 718 Personal Edition - Installation - updated by pega_pe_nitro project"/>
 			
 	<page
 			type="text"
 			name="PE-OverviewAndPrerequisites"
 			displayText="Overview and Prerequisites"
 			htmlResource="/resources/overviewAndPrerequisites.htm"
+			textResource="/resources/overviewAndPrerequisites.htm"
 			overflow="true"
 			imageResource="/resources/pega-grey-banner.png"/>
 					
@@ -76,7 +78,9 @@
 		<target target="Initialization" defaultValue="true" displayText="Initialization" force="true"/>
 		<target target="Database Server Installation" defaultValue="true" displayText="Install Database Server" force="true"/>
 		<target target="Data Load" defaultValue="true" displayText="Load PRPC Database" force="true"/>
-		<target target="Configuration" defaultValue="true" displayText="Create Desktop Shortcuts" force="true"/>
+		<target target="Configuration" defaultValue="true" displayText="Create Administrative Scripts" force="true"/>
++		<target target="OSX Shortcuts" defaultValue="false" displayText="Create OSX Application Shortcuts" osSpecific="mac" force="false"/>
++		<target target="Configuration" defaultValue="false" displayText="Create Windows Desktop Shortcuts" force="true"/>
 		<target target="PRPC Launching" defaultValue="true" displayText="Launch PRPC"/>
 		
 		<comment
@@ -101,7 +105,7 @@
 		
 		<directory
 				property="install.dir"
-				defaultValue="C:\"
+				defaultValue="/usr/local/PegaPE"
 				defaultValueWin="C:\"
 				displayText="Install Directory:"
 				checkExists="true"/>
@@ -159,7 +163,7 @@
 				displayText=""/>
 		<comment
 				displayText=""/>
-		<portavailabilitybutton alignment="right" />	
+
 	</page>
 	
 	<!--  page type="progress" shows a progress page with the install button -->
### nitro.patch

### pom.xml.patch
--- pom.xml	2019-10-02 15:19:23.307000000 -0400
+++ pom.xml.surefire	2019-10-02 16:40:11.196000000 -0400
@@ -95,6 +95,11 @@
 					</compilerArguments>
 				</configuration>
 			</plugin>
+                        <plugin>
+                                <groupId>org.apache.maven.plugins</groupId>
+                                <artifactId>maven-surefire-plugin</artifactId>
+                                <version>MVNSRFR_VER</version>
+                        </plugin>
 			<plugin>
 				<groupId>org.apache.maven.plugins</groupId>
 				<artifactId>maven-jar-plugin</artifactId>
### pom.xml.patch

