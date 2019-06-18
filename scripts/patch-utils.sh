#Break execution on any error received
function require_package {
	package_name=$1
	printf "\e[32mPackage required %s: \e[0m" "${package_name}"
	#Supress error code and message in case the package is not installed
	exec 3>&2
	exec 2>/dev/null
	set +e
	installed=$(dpkg-query -W -f='${Status}' ${package_name} | grep -c "ok installed" || true)
	exec 2>&3
	set -e
	
	if [ $installed -eq 0 ];
	then
		echo -e "\e[31m - not found, installing now...\e[0m"
		sudo apt-get install ${package_name} -y
		echo -e "\e[32mMissing package installed\e[0m"
	else
		echo -e "\e[32m - found\e[0m"
	fi
}

#Based on the current kernel version select the branch name to fetch the kernel source code
# The reference name are pulled here : http://kernel.ubuntu.com/git/ubuntu/ubuntu-xenial.git/
# As of Jun 21, the status is 
#	Branch		Commit message								Author							Age
#	hwe			UBUNTU: Ubuntu-hwe-4.15.0-24.26~16.04.1		Andy Whitcroft					6 days
#	hwe-edge	UBUNTU: Ubuntu-hwe-4.15.0-23.25~16.04.1		Kleber Sacilotto de Souza		4 weeks
#	hwe-zesty	UBUNTU: Ubuntu-hwe-4.10.0-43.47~16.04.1		Thadeu Lima de Souza Cascardo	6 months
#	master		UBUNTU: Ubuntu-4.4.0-128.154				Stefan Bader					4 weeks
#	master-next	UBUNTU: SAUCE: Redpine: fix soft-ap invisible issue	Sanjay Kumar Konduri	2 days

#Ubuntu bionic repo : http://kernel.ubuntu.com/git/ubuntu/ubuntu-bionic.git/
#	master		UBUNTU: Ubuntu-4.15.0-23.25					Stefan Bader					4 weeks
#	master-next	ixgbe/ixgbevf: Free IRQ when PCI error recovery removes the device	Mauro S M Rodrigues	2 days

#Ubuntu cosmic repo : http://kernel.ubuntu.com/git/ubuntu/ubuntu-cosmic.git/
#	master		UBUNTU: Ubuntu-4.18.0-22.23	Marcelo Henrique Cerri	2 weeks
#	master-next	UBUNTU: Ubuntu-4.18.0-23.24	Stefan Bader			6 days
# 	tag			UBUNTU: Ubuntu-4.18.0-21.22	Stefan Bader			5 weeks

function choose_kernel_branch {

	# Split the kernel version string
	IFS='.' read -a kernel_version <<< "$1"

	if [ "$2" = "xenial" ];
	then
		case "${kernel_version[1]}" in
		"4")									# Kernel 4.4. is managed on master branch
			echo master
			;;
		"8")								 	# kernel 4.8 is deprecated and available via explicit tags. Currently on 4.8.0-58
			echo Ubuntu-hwe-4.8.0-58.63_16.04.1
			;;
		"10")								 	# kernel 4.10 is managed on branch hwe-zesty as of 1.1.2018
			echo hwe-zesty
			;;
		"13")								 	# kernel 4.13 is on hwe branch and replaced with 4.15. Provide source from a tagged version instead (back-compat)
			echo Ubuntu-hwe-4.13.0-45.50_16.04.1
			;;
		"15")								 	# kernel 4.15 for Ubuntu xenial is either hwe or hwe-edge
			echo hwe
			;;
		*)
			#error message shall be redirected to stderr to be printed properly
			echo -e "\e[31mUnsupported kernel version $1 . The patches are maintained for Ubuntu LTS with kernel versions 4.4, 4.8, 4.10 and 4.13 only\e[0m" >&2
			exit 1
			;;
		esac
	elif [ "$2" = "bionic" ];
	then
		case "${kernel_version[1]}" in
		"15")								 	# kernel 4.15 for Ubuntu 18/Bionic Beaver
			echo master
			;;
		*)
			#error message shall be redirected to stderr to be printed properly
			echo -e "\e[31mUnsupported kernel version $1 . The patches are maintained for Ubuntu Bionic LTS with kernel 4.15 only\e[0m" >&2
			exit 1
			;;
		esac
	elif [ "$2" = "cosmic" ];
	then
		case "${kernel_version[1]}" in
		"18")									# Kernel 4.18.0-21-generic is managed on branch Ubuntu-4.18.0-21.22
			echo Ubuntu-4.18.0-21.22
			;;
		"19")								 	# kernel 4.19
			echo -e "\e[31mUnsupported kernel version $1 .\e[0m" >&2
			exit 1
			;;
		*)
			#error message shall be redirected to stderr to be printed properly
			echo -e "\e[31mUnsupported kernel version $1 . The patches are maintained for Ubuntu LTS with kernel versions 4.4, 4.8, 4.10 and 4.13 only\e[0m" >&2
			exit 1
			;;
		esac
	else
		echo -e "\e[31mUnsupported distribution $2 kernel version $1 .\e[0m" >&2
		exit 1
	fi
}

function try_unload_module {
	unload_module_name=$1
	op_failed=0

	sudo modprobe -r ${unload_module_name} || op_failed=$?

	if [ $op_failed -ne 0 ];
	then
		echo -e "\e[31mFailed to unload module $unload_module_name. error type $op_failed . Operation is aborted\e[0m" >&2
		exit 1
	fi
}

function try_load_module {
	load_module_name=$1
	op_failed=0

	sudo modprobe ${load_module_name} || op_failed=$?

	if [ $op_failed -ne 0 ];
	then
		echo -e "\e[31mFailed to reload module $load_module_name. error type $op_failed . Operation is aborted\e[0m"  >&2
		exit 1
	fi
}

function try_module_insert {
	module_name=$1
	src_ko=$2
	tgt_ko=$3
	backup_available=1
	dependent_modules=""

	printf "\e[32mReplacing \e[93m\e[1m%s \e[32m:\n\e[0m" ${module_name}

	#Check if the module is loaded, and if does - are there dependent kernel modules.
	#Unload those first, then unload the requsted module and proceed with replacement
	#  lsmod | grep ^videodev
	#videodev              176128  4 uvcvideo,v4l2_common,videobuf2_core,videobuf2_v4l2
	# In the above scenario videodev cannot be unloaded untill all the modules listed on the right are unloaded
	# Note that in case of multiple dependencies we'll remove only modules one by one starting with the first on the list
	# And that the modules stack unwinding will start from the last (i.e leaf) dependency,
	# for instance : videobuf2_core,videobuf2_v4l2,uvcvideo will start with unloading uvcvideo as it should automatically unwind dependent modules
	if [ $(lsmod | grep ^${module_name} | wc -l) -ne 0 ];
	then
		dependencies=$(lsmod | grep ^${module_name} | awk '{printf $4}')
		dependent_module=$(lsmod | grep ^${module_name} | awk '{printf $4}' | awk -F, '{printf $NF}')
		if [ ! -z "$dependencies" ];
		then
			printf "\e[32m\tModule \e[93m\e[1m%s \e[32m\e[21m is used by \e[34m$dependencies\n\e[0m" ${module_name}
		fi
		if echo $dependencies | grep -w uvcvideo > /dev/null; then
			try_unload_module uvcvideo
		fi
		while [ ! -z "$dependent_module" ]
		do
			printf "\e[32m\tUnloading dependency \e[34m$dependent_module\e[0m\n\t"
			dependent_modules+="$dependent_module "
			try_unload_module $dependent_module
			dependent_module=$(lsmod | grep ^${module_name} | awk '{printf $4}' | awk -F, '{printf $NF}')
		done

		# Unload existing modules if resident
		printf "\e[32mModule is resident, unloading ... \e[0m"
		try_unload_module ${module_name}
		printf "\e[32m succeeded. \e[0m\n"
	fi

	# backup the existing module (if available) for recovery
	if [ -f ${tgt_ko} ];
	then
		sudo cp ${tgt_ko} ${tgt_ko}.bckup
	else
		backup_available=0
	fi

	# copy the patched module to target location
	sudo cp ${src_ko} ${tgt_ko}

	# try to load the new module
	modprobe_failed=0
	printf "\e[32mApplying the patched module ... \e[0m"
	sudo modprobe ${module_name} || modprobe_failed=$?

	# Check and revert the backup module if 'modprobe' operation crashed
	if [ $modprobe_failed -ne 0 ];
	then
		echo -e "\e[31mFailed to insert the patched module. Operation is aborted, the original module is restored\e[0m"
		echo -e "\e[31mVerify that the current kernel version is aligned to the patched module version\e[0m"
		if [ ${backup_available} -ne 0 ];
		then
			sudo cp ${tgt_ko}.bckup ${tgt_ko}
			sudo modprobe ${module_name}
			printf "\e[34mThe original \e[33m %s \e[34m module was reloaded\n\e[0m" ${module_name}
		fi
		exit 1
	else
		# Everything went OK, delete backup
		printf "\e[32m succeeded\n\e[0m"
		sudo rm ${tgt_ko}.bckup
	fi

	# Reload all dependent modules recursively
	if [ ! -z "$dependent_modules" ];
	then
		#Retrieve the list of dependent modules that were unloaded
		modules_list=(${dependent_modules})
		for (( idx=${#modules_list[@]}-1 ; idx>=0 ; idx-- ));
		do
			printf "\e[32m\tReloading dependent kernel module \e[34m${modules_list[idx]} \e[32m... \e[0m"
			try_load_module ${modules_list[idx]}
			printf "\e[32m succeeded. \e[0m\n"
		done
	fi
	printf "\n"
}
