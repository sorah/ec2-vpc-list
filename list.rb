require 'aws-sdk-ec2'
require 'json'
require 'erb'
require 'fileutils'

Aws.config[:logger] = Logger.new($stderr)

def link_console_vpc(region, vpc_id)
  "[`#{vpc_id}`](https://console.aws.amazon.com/vpc/home?region=#{region}#vpcs:filter=#{vpc_id})"
end

def link_console_pcx(region, pcx_id)
  "[`#{pcx_id}`](https://console.aws.amazon.com/vpc/home?region=#{region}#PeeringConnections:vpcPeeringConnectionId=#{pcx_id})"
end

def dot_vpc_key(key)
  key.gsub(%r{[/\-]}, '_')
end

def vpc_name(vpc)
  vpc.tags.find { |_| _.key == 'ShortName' }&.value || \
  vpc.tags.find { |_| _.key == 'Name' }&.value || \
  vpc.id
end

  ##

def regions
  @regions ||= Aws::EC2::Client.new(region: ENV['AWS_DEFAULT_REGION'] || 'ap-northeast-1').describe_regions.regions.map(&:region_name)
end

vpcs_ts = regions.map do |region|
  Thread.new do
    ec2 = Aws::EC2::Resource.new(region: region)
    ec2.vpcs().map { |vpc| ["#{region}/#{vpc.id}", vpc] }
  end
end

pcxs_ts = regions.map do |region|
  Thread.new do
    ec2 = Aws::EC2::Resource.new(region: region)
    [region, ec2.vpc_peering_connections(filters: [name: 'status-code', values: %w(active)]).map { |_| [_.id, _] }.sort_by(&:first).to_h]
  end
end

@vpcs = vpcs_ts.flat_map(&:value).sort_by(&:first).to_h
@pcxs = pcxs_ts.map(&:value).sort_by(&:first).to_h

@vpcs_by_region = @vpcs.group_by { |key, vpc|
  key.split(?/,2).first
}.map { |region, vpcs|
  [region, vpcs.to_h]
}.to_h

@pcxs_i_by_vpc = @pcxs.each_value.inject({}) do |r, ps|
  ps.each_value.group_by { |_| "#{_.requester_vpc_info.region}/#{_.requester_vpc_info.vpc_id}" }.each do |k,s|
    (r[k] ||= {})
    s.each do |pcx|
      r[k][pcx.id] = pcx
    end
  end
  r
end.transform_values(&:values)


@pcxs_r_by_vpc = @pcxs.each_value.inject({}) do |r, ps|
  ps.each_value.group_by { |_| "#{_.accepter_vpc_info.region}/#{_.accepter_vpc_info.vpc_id}" }.each do |k,s|
    (r[k] ||= {})
    s.each do |pcx|
      r[k][pcx.id] = pcx
    end
  end
  r
end.transform_values(&:values)

@pcxs_by_vpc = {}.tap do |h|
  @pcxs_i_by_vpc.each do |key, s|
    (h[key] ||= []).concat(s)
  end
  @pcxs_r_by_vpc.each do |key, s|
    (h[key] ||= []).concat(s)
  end
end

###

FileUtils.mkdir_p "./out"
File.write "./out/graph.dot", ERB.new(File.read(File.join(__dir__, 'graph.dot.erb')), nil, '-').result(binding)
File.write "./out/README.md", ERB.new(File.read(File.join(__dir__, 'list.md.erb')), nil, '-').result(binding)

File.open('./out/graph.svg', 'w') do |io|
  system("dot", "-Tsvg", "./out/graph.dot", out: io) or raise
end
File.open('./out/graph.png', 'w') do |io|
  system("dot", "-Tpng", "./out/graph.dot", out: io) or raise
end
