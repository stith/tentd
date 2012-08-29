require 'spec_helper'

describe TentServer::API::Followers do
  def app
    TentServer::API.new
  end

  def link_header(entity_url)
    %Q(<#{entity_url}/tent/profile>; rel="profile"; type="%s") % TentClient::PROFILE_MEDIA_TYPE
  end

  def tent_profile(entity_url)
    %Q({"https://tent.io/types/info/core/v0.1.0":{"licenses":["http://creativecommons.org/licenses/by/3.0/"],"entity":"#{entity_url}","servers":["#{entity_url}/tent"]}})
  end

  let(:http_stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:follower) { Fabricate(:follower) }

  describe 'POST /followers' do
    let(:follower_entity_url) { "https://alex.example.org" }
    let(:follower_data) do
      {
        "entity" => follower_entity_url,
        "licenses" => ["http://creativecommons.org/licenses/by-nc-sa/3.0/"],
        "types" => ["https://tent.io/types/posts/status/v0.1.x#full", "https://tent.io/types/posts/photo/v0.1.x#meta"]
      }
    end

    it 'should perform discovery' do
      http_stubs.head('/') { [200, { 'Link' => link_header(follower_entity_url) }, ''] }
      http_stubs.get('/tent/profile') {
        [200, { 'Content-Type' => TentClient::PROFILE_MEDIA_TYPE }, tent_profile(follower_entity_url)]
      }
      TentClient.any_instance.stubs(:faraday_adapter).returns([:test, http_stubs])

      json_post '/followers', follower_data, 'tent.entity' => 'smith.example.com'
      http_stubs.verify_stubbed_calls
    end

    it 'should error if discovery fails' do
      http_stubs.head('/') { [404, {}, 'Not Found'] }
      http_stubs.get('/') { [404, {}, 'Not Found'] }
      TentClient.any_instance.stubs(:faraday_adapter).returns([:test, http_stubs])

      json_post '/followers', follower_data, 'tent.entity' => 'smith.example.com'
      expect(last_response.status).to eq(404)
    end

    it 'should fail if entity identifiers do not match' do
      http_stubs.head('/') { [200, { 'Link' => link_header(follower_entity_url) }, ''] }
      http_stubs.get('/tent/profile') {
        [200, { 'Content-Type' => TentClient::PROFILE_MEDIA_TYPE }, tent_profile('https://otherentity.example.com')]
      }
      TentClient.any_instance.stubs(:faraday_adapter).returns([:test, http_stubs])

      json_post '/followers', follower_data, 'tent.entity' => 'smith.example.com'
      expect(last_response.status).to eq(409)
    end

    context 'when discovery success' do
      before do
        http_stubs.head('/') { [200, { 'Link' => link_header(follower_entity_url) }, ''] }
        http_stubs.get('/tent/profile') {
          [200, { 'Content-Type' => TentClient::PROFILE_MEDIA_TYPE }, tent_profile(follower_entity_url)]
        }
        TentClient.any_instance.stubs(:faraday_adapter).returns([:test, http_stubs])
      end

      it 'should create follower db record and respond with hmac secret' do
        expect(lambda { json_post '/followers', follower_data, 'tent.entity' => 'smith.example.com' }).
          to change(TentServer::Model::Follower, :count).by(1)
        expect(last_response.status).to eq(200)
        follow = TentServer::Model::Follower.last
        expect(last_response.body).to eq({
          "id" => follow.id,
          "mac_key_id" => follow.mac_key_id,
          "mac_key" => follow.mac_key,
          "mac_algorithm" => follow.mac_algorithm
        }.to_json)
      end

      it 'should create notification subscription for each type given' do
        expect(lambda { json_post '/followers', follower_data, 'tent.entity' => 'smith.example.com' }).
          to change(TentServer::Model::NotificationSubscription, :count).by(2)
        expect(last_response.status).to eq(200)
        expect(TentServer::Model::NotificationSubscription.last.view).to eq('meta')
      end
    end
  end

  describe 'GET /followers' do
    it 'should return a list of followers'
  end

  describe 'GET /followers/:id' do
    it 'should respond with follower json' do
      json_get "/followers/#{follower.id}"
      expect(last_response.body).to eq(follower.as_json(:only => [:id, :groups, :entity, :licenses, :type, :mac_key_id, :mac_algorithm]).to_json)
    end

    it 'should respond with 404 if no follower exists with :id' do
      json_get "/followers/invalid-id"
      expect(last_response.status).to eq(404)
    end
  end

  describe 'PUT /followers/:id' do
    it 'should update follower licenses' do
      data = {
        :licenses => ["http://creativecommons.org/licenses/by/3.0/"]
      }
      json_put "/followers/#{follower.id}", data
      follower.reload
      expect(follower.licenses).to eq(data[:licenses])
    end

    context '' do
      before(:all) do
        @data = {
          :entity => URI("https://chunky-bacon.example.com"),
          :profile => { :entity => URI("https:://chunky-bacon.example.com") },
          :type => :following,
          :mac_key_id => '12345',
          :mac_key => '12312',
          :mac_algorithm => 'sdfjhsd',
          :mac_timestamp_delta => '124123'
        }
      end
      [:entity, :profile, :mac_key_id, :mac_key, :mac_algorithm, :mac_timestamp_delta].each do |property|
        it "should not update #{property}" do
          original_value = follower.send(property)
          data = { property => @data[property] }
          json_put "/followers/#{follower.id}", data
          follower.reload
          expect(follower.send(property)).to eq(original_value)
        end
      end
    end

    it 'should update follower type notifications' do
      data = {
        :types => follower.notification_subscriptions.map {|ns| ns.type.to_s}.concat(["https://tent.io/types/post/video/v0.1.x#meta"])
      }
      expect( lambda { json_put "/followers/#{follower.id}", data } ).
        to change(TentServer::Model::NotificationSubscription, :count).by (1)

      follower.reload
      data = {
        :types => follower.notification_subscriptions.map {|ns| ns.type.to_s}[0..-2]
      }
      expect( lambda { json_put "/followers/#{follower.id}", data } ).
        to change(TentServer::Model::NotificationSubscription, :count).by (-1)
    end
  end

  describe 'DELETE /followers/:id' do
    it 'should delete follower' do
      follower # create follower
      expect(lambda { delete "/followers/#{follower.id}" }).to change(TentServer::Model::Follower, :count).by(-1)
      expect(last_response.status).to eq(200)
    end

    it 'should respond with 404 if no follower exists with :id' do
      delete "/followers/invalid-id"
      expect(last_response.status).to eq(404)
    end
  end
end