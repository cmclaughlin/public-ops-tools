require './elb_manager'
require './get_logger'

RSpec.configure do |config|
  config.mock_with :rspec do |c|
    c.syntax = [:should, :expect]
  end
end

describe 'update_elb' do
  describe 'update_elb checks' do

    before :each do
      # Create a mocked object to track RightScale API calls
      @rs_mock = double('RightScale')
      allow(@rs_mock).to receive(:new) { @client }
      @sa_mock = double('ServerArray')
      stub(:find_server_array) { @sa_mock }
    end

    it "should raise exception with bad action" do
      expect {
        update_elb(false, @rs_mock, 'fake_elb', 'fake_sa', 'fake_url', 'bad')
      }.to raise_error(/Action must be/)
    end

    it "elb => foo_elb, server_array => foo_sa, action => add" do

      @sa_mock.should_receive(:multi_run_executable).with(
        :right_script_href => '/api/right_scripts/438671001',
        :inputs => { 'ELB_NAME' => 'text:foo_elb' } ) { @task_mock }

      update_elb(false, @rs_mock, 'foo_elb', 'foo_sa', 'staging', 'add')
    end

    it "elb => foo_elb, server_array => foo_sa, action => remove" do

      @sa_mock.should_receive(:multi_run_executable).with(
        :right_script_href => '/api/right_scripts/396277001',
        :inputs => { 'ELB_NAME' => 'text:foo_elb' } ) { @task_mock }

      update_elb(false, @rs_mock, 'foo_elb', 'foo_sa', 'staging', 'remove')
    end

  end
end
