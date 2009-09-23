# This module acts as a client to the FuzzServer code, it connects in and sends a
# db_ready singal, then waits for results. For crashes that needs to be traced, it
# interacts with the TraceServer via a reference to the parent class, by putting
# data directly onto the queues or firing callbacks.
#
# To be honest, if you don't understand this part, (which is completely fair) 
# you're better off reading the EventMachine documentation, not mine.
#
# ---
# This file is part of the Metafuzz fuzzing framework.
# Author: Ben Nagy
# Copyright: Copyright (c) Ben Nagy, 2006-2009.
# License: All components of this framework are licensed under the Common Public License 1.0. 
# http://www.opensource.org/licenses/cpl1.0.txt

class FuzzServerConnection < EventMachine::Connection

    VERSION="2.0.0"
    COMPONENT="DB:FSConn"
    Queue=Hash.new {|hash, key| hash[key]=Array.new}

    def self.new_ack_id
        @ack_id||=rand(2**31)
        @ack_id+=1
    end

    def initialize( parent_klass )
        @server_klass=parent_klass
    end

    # Used for the 'heartbeat' messages that get resent when things
    # are in an idle loop
    def dump_debug_data( msg_hash )
        begin
            port, ip=Socket.unpack_sockaddr_in( get_peername )
            puts "OUT: #{msg_hash['verb']} to #{ip}:#{port}"
            sleep 1
        rescue
            puts "OUT: #{msg_hash['verb']}, not connected yet."
            sleep 1
        end
    end

    def start_idle_loop
        msg_hash={'verb'=>'db_ready'}
        dump_debug_data( msg_hash ) if @server_klass.debug
        self.reconnect(@server_klass.fuzzserver_ip, @server_klass.fuzzserver_port) if self.error?
        send_data @handler.pack(FuzzMessage.new(msg_hash).to_s)
        waiter=EventMachine::DefaultDeferrable.new
        waiter.timeout(@server_klass.poll_interval)
        waiter.errback do
            Queue[:idle].shift
            puts "#{COMPONENT}: Timed out sending #{msg_hash['verb']}. Retrying."
            start_idle_loop
        end
        Queue[:idle] << waiter
    end

    def cancel_idle_loop
        Queue[:idle].shift.succeed
        raise RuntimeError, "#{COMPONENT}: idle queue not empty?" unless Queue[:idle].empty?
    end

    def send_once( msg_hash )
        self.reconnect(@server_klass.server_ip, @server_klass.server_port) if self.error?
        dump_debug_data( msg_hash ) if @sderver_klass.debug
        send_data @handler.pack(FuzzMessage.new(msg_hash).to_s)
    end

    def send_ack( ack_id, extra_data={} )
        msg_hash={
            'verb'=>'ack_msg',
            'ack_id'=>ack_id,
        }
        msg_hash.merge! extra_data
        dump_debug_data( msg_hash ) if @server_klass.debug
        self.reconnect(@server_klass.fuzzserver_ip, @server_klass.fuzzserver_port) if self.error?
        # We only send one ack. If the ack gets lost and the sender cares
        # they will resend.
        send_data @handler.pack(FuzzMessage.new(msg_hash).to_s)
    end

    def send_to_tracebot( crashfile, template_hash )
        if template=@server_klass.template_cache[template_hash]
            # good
        else
            template=@server_klass.db.get_template( template_hash )
        end
        encoded_template=Base64::encode64 template
        encoded_crashfile=Base64::encode64 crashfile
        if tracebot=@server_klass.queue[:tracebots].shift
            tracebot.succeed( encoded_crashfile, encoded_template, db_id )
        else
            msg.hash={
                'verb'=>'new_trace_pair'
            }
            @server_klass.queue[:untraced] << msg_hash
        end
    rescue
        puts $!
    end

    def handle_new_template( msg )
        raw_template=Base64::decode64( msg.template )
        template_hash=Digest::MD5.hexdigest( raw_template )
        if template_hash==msg.template_hash
            unless @server_klass.template_cache.has_key? template_hash
                @server_klass.template_cache[template_hash]=raw_template
                @server_klass.db.add_template raw_template, template_hash
            end
            send_ack msg.ack_id
            start_idle_loop
        else
            # mismatch. Drop, the fuzzserver will resend
            start_idle_loop
        end
    rescue
        puts $!
    end

    def handle_test_result( msg )
        server_id, template_hash, result_string=msg.id, msg.template_hash, msg.status
        if result_string=='crash'
            crash_file=Base64::decode64( msg.crashfile )
            crash_data=Base64::decode64( msg.crashdata )
            db_id=@server_klass.db.add_result(
                result_string,
                crash_data,
                crash_file,
                template_hash
            )
            #Let's get the DB working first...
            #send_to_tracebot( crashfile, template_hash, db_id)
        else
            db_id=@server_klass.db.add_result result_string
        end
        send_ack( msg.ack_id, 'db_id'=>db_id )
        start_idle_loop
    rescue
        puts $!
    end

    def post_init
        @handler=NetStringTokenizer.new
        puts "#{COMPONENT}: Trying to connect to #{@server_klass.fuzzserver_ip} : #{@server_klass.fuzzserver_port}" 
        start_idle_loop
    rescue
        puts $!
    end

    # FuzzMessage#verb returns a string so self.send activates
    # the corresponding 'handle_' instance method above, 
    # and passes the message itself as a parameter.
    def receive_data(data)
        @handler.parse(data).each {|m| 
            msg=FuzzMessage.new(m)
            if @server_klass.debug
                port, ip=Socket.unpack_sockaddr_in( get_peername )
                puts "IN: #{msg.verb} from #{ip}:#{port}"
                sleep 1
            end
            cancel_idle_loop
            self.send("handle_"+msg.verb.to_s, msg)
        }
    end

    def method_missing( meth, *args )
        raise RuntimeError, "Unknown Command: #{meth.to_s}!"
    end

end
