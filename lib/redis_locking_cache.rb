require "forwardable"
require "redis"
require "securerandom"

class RedisLockingCache
  extend Forwardable

  def initialize(redis)
    @redis = redis
  end

  def_delegators :@redis, :flushall

  def fetch(key, opts = {}, &block)
    expires_in = opts.fetch(:expires_in, 1)
    expires_in_ms = (expires_in * 1000).to_i
    lock_timeout = opts.fetch(:lock_timeout, 1)
    lock_wait = opts.fetch(:lock_wait, 0.025)
    cache_wait = opts.fetch(:cache_wait, 1)

    lock_key = "#{key}:lock"
    expiry_key = "#{key}:expiry"

    cached, expiry = @redis.mget(key, expiry_key)

    if cached.nil?
      cache_wait_expiry = Time.now.to_f + cache_wait

      while cached.nil? && Time.now.to_f < cache_wait_expiry
        unless cached = @redis.get(key)
          lock_id = SecureRandom.hex(16)
          if @redis.set(lock_key, lock_id, nx: true, ex: lock_timeout)
            begin
              cached = block.call
              @redis.set(key, cached)
              @redis.set(expiry_key, 1, px: expires_in_ms)
            ensure
              if @redis.get(lock_key) == lock_id
                @redis.del(lock_key)
              end
            end
          else
            sleep(lock_wait)
          end
        end
      end
    elsif expiry.nil?
      # TODO remove lock key
      lock_id = SecureRandom.hex(16)
      if @redis.set(lock_key, 1, nx: true, ex: lock_timeout)
        begin
          cached = block.call
          @redis.set(key, cached)
          @redis.set(expiry_key, 1, px: expires_in_ms)
        rescue
          # TODO bubble up errors when appropriate
        ensure
          if @redis.get(lock_key) == lock_id
            @redis.del(lock_key)
          end
        end
      end
    end

    cached
  end
end