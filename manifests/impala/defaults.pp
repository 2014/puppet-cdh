# == Class: cdh::impala::defaults
#
# Default Impala configs
#
class cdh::impala::defaults {
  $version     = 'installed'
  $cgroup_path = '/sys/fs/cgroup/impala'
}