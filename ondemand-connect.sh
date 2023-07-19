#! /bin/bash

#
# 2022/03/17 Created by y_yoshida
# 2023/07/19 Modified by yoshiylife
# End of history.

usage() {
    echo $"Usage: $0 [-hqv] managed_node [ssh_port] [aws_profile]" 1>&2
    echo $"Example: ${0##*/} i-123456789" 1>&2
    echo $"Example: ${0##*/} i-123456789 12322" 1>&2
    exit 1
}

quiet=0
verbose=0
while getopts hqv OPT
do
    case $OPT in
    q)      quiet=1;;
    v)      verbose=1;;
    h)      usage;;
    \?)     usage;;
    esac
done
shift $((OPTIND - 1))
[[ $# -lt 1 ]] && usage

managed_node="$1"
ssh_port="${2:-22}"
aws_profile="${3:-default}"
ipaddress=$(curl -s ifconfig.me)

check() {
    message="$1"
    output="$2"
    rc=${3:-$?}
    state=''
    prefix=''
    [[ $rc -eq 0 && $verbose -eq 0 ]] || prefix=$"[${0##*/} $managed_node $ssh_port ${3:+--profile $"$aws_profile"}] "
    [[ $rc -eq 0 ]] || prefix=$"${prefix}ERROR($rc): "

    [[ $rc -eq 0 && $quiet -ne 0 ]] || echo $"$prefix$message" 1>&2
    [[ $verbose -eq 0 || -z $output ]] || echo $"$prefix$output" 1>&2
    [[ $rc -eq 0 ]] || exit $rc
}

# Check status of Security Group
name=$(aws ec2 describe-tags --query $"Tags[?ResourceId==\`$managed_node\` && Key==\`Name\`].Value" --output text ${3:+--profile $"$aws_profile"})
host=$(echo $name | cut -d@ -f 1)
sgname=$"ondemand-$host-sg"
sgid=$(aws ec2 describe-security-groups --query $"SecurityGroups[?GroupName==\`$sgname\`].GroupId | [0]" --output text ${3:+--profile $"$aws_profile"})
check $"ec2 describe-security-groups" $"Found $sgid for $sgname"
if [[ -z $"$sgid" ]]; then
    check $"Not found SecurityGroups: $sgname" '' 2
fi

# Check status of Instance
running=0
InstanceStatus=$(aws ec2 describe-instance-status --include-all-instances --instance-ids $managed_node --query 'InstanceStatuses[*].InstanceState.Name' --output text ${3:+--profile $"$aws_profile"})
check $"ec2 describe-instance-status" $"$InstanceStatus"
case "$InstanceStatus" in

    'pending' | 'rebooting')
        # Nothing to do
        ;;

    'running')
        running=1
        ;;

    'stopping')
        check $"Wait a while for the instance stopped..."
        output=$(aws ec2 wait instance-stopped --instance-ids $managed_node ${3:+--profile $"$aws_profile"})
        check $"wait instance-stopped" $"$output"
        output=$(aws ec2 start-instances --instance-ids $managed_node ${3:+--profile $"$aws_profile"})
        check $"start-instances" $"$output"
        ;;

    'stopped')
        output=$(aws ec2 start-instances --instance-ids $managed_node ${3:+--profile $"$aws_profile"})
        check $"start-instances" $"$output"
        ;;

    'shutting-down' | 'terminated')
        check $"Instance is $InstanceStatus" '' 2
        ;;

    *)
        check $"describe-instance-status: $InstanceStatus" '' 2
        ;;

esac

# Set security groups
query=$"SecurityGroupRules[?GroupId==\`$sgid\` && CidrIpv4==\`$ipaddress/32\` && contains(Description,\`ondemand-$host-sg\`)].SecurityGroupRuleId"
output=$(aws ec2 describe-security-group-rules --query $"$query" --output text ${3:+--profile $"$aws_profile"})
check $"ec2 describe-security-group-rules" $"$output"
if [[ -z $"$output" ]]; then
    tags=$"ResourceType=security-group-rule,Tags=[{Key=Name,Value=$host-ondemand}]"
    auth_ingress=$"IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$ipaddress/32,Description=$host-ondemand}]"
    output=$(aws ec2 authorize-security-group-ingress --group-id $"$sgid" --ip-permissions $"$auth_ingress" --tag-specifications $"$tags" ${3:+--profile $"$aws_profile"})
    check $"ec2 authorize-security-group-ingress" $"$output"
    auth_egress=$"IpProtocol=-1,FromPort=-1,ToPort=-1,IpRanges=[{CidrIp=$ipaddress/32,Description=ondemand-$host-sg}]"
    output=$(aws ec2 authorize-security-group-egress --group-id $"$sgid" --ip-permissions $"$auth_egress" --tag-specifications $"$tags" ${3:+--profile $"$aws_profile"})
    check $"ec2 authorize-security-group-egress" $"$output"
fi

# Run the instance
[[ $running -ne 0 ]] || echo $"Wait a while for the instance ok..." 1>&2
output=$(aws ec2 wait instance-status-ok --include-all-instances --instance-ids $managed_node ${3:+--profile $"$aws_profile"})
check $"wait instance-status-ok" $"$output"

aws ssm start-session --target "$managed_node" --document-name AWS-StartSSHSession --parameters $"portNumber=$ssh_port" ${3:+--profile $"$aws_profile"}
exit $?
# End of file.
