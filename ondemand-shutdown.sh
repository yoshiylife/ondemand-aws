#! /bin/bash +e

#
# 2022/03/24 Created by y_yoshida
# 2023/07/19 Modified by yoshiylife
# End of history.

usage() {
    echo $"Usage: $0 max_startup_time_in_seconds [hostname] [aws_profile]" 1>&2
    echo $"    Example: ${0##*/} 300" 1>&2
    exit 1
}

shift $((OPTIND - 1))
[[ $# -lt 1 ]] && usage
max_startup_time=$"$1" # in seconds
hostname=$"$2"
aws_profile=$"${3:-default}"

# Check if bootstrup is in progress.
uptime=$(/usr/bin/uptime -s)
intime=$(date +$"%Y-%m-%d %T" --date $"-$max_startup_time seconds") # Time expected to complete startup
[[ $"$uptime" > $"$intime" ]] && exit 0; #echo "Skip the instance stop for initializing."

# Check if an SSH connection exists.
count=$(ps -e -o command | grep '^sshd: ' | wc -l)
[[ $"$?" -ne 0 || $"$count" -gt 0 ]] && exit 0; #echo "Skip the instance stop because sessions exist."

#
# Cleanup security group rules
#
# To delete, security group name and keyword
if [[ -z $"$hostname" ]]
then
	instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
	name=$(aws ec2 describe-tags --output text --query "Tags[? ResourceId==\`$instance_id\` && Key==\`Name\`].Value" ${3:+--profile $"$aws_profile"});
	hostname=$(echo $name | cut -d@ -f 1)
fi
sgname=$"ondemand-$hostname-sg"
keyword=$"$hostname-ondemand"

aws ec2 describe-security-groups --query $"SecurityGroups[?GroupName==\`$sgname\`].GroupId" --output text | while read sgid
do
	query=$"SecurityGroupRules[? GroupId==\`$sgid\` && Tags[? Key==\`Name\` && Value==\`$keyword\`] && Description==\`$keyword\`].[IsEgress,SecurityGroupRuleId]"
	aws ec2 describe-security-group-rules --query $"$query" --output text ${3:+--profile $"$aws_profile"} | while read is_egress sgrid
	do
		security_gid_rid=$"--group-id $sgid --security-group-rule-ids $sgrid --output text"
		result=$(aws ec2 revoke-security-group-$("${is_egress,,}" && echo 'egress' || echo 'ingress') $security_gid_rid --output text ${3:+--profile $"$aws_profile"})
	done
done

# Go to power-off
sudo /sbin/shutdown -h now > /dev/null 2>&1

exit 0
# End of file
