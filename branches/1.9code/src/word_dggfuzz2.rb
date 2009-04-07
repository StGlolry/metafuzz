require 'rubygems'
require 'thread'
require 'fuzzer'
require 'diff/lcs'
require 'wordstruct'
require 'ole/storage'
require 'mutations'
require 'tempfile'
require 'generators'
require 'digest/md5'

class Producer < Generators::NewGen

    START_AT=0
    SEEN_LIMIT=5000

    Template=File.open( File.join(Config["WORK DIR"],"boof.doc"),"rb") {|io| io.read}
    #Template=File.open( File.expand_path("~/wordcrashes/crash-192242.doc"),"rb") {|io| io.read}
    Template.freeze

    def hexdump(str)
        ret=""
        str.unpack('H*').first.scan(/.{2}/).each_slice(16) {|s| 
            ret << "%-50s" % s.join(' ') 
            ret << s.map {|e| e.hex}.pack('c*').tr("\000-\037\177-\377",'.')
            ret << "\n"
        }
        ret
    end

    def recursive_cartprod( atom )
        if atom.is_a?(Binstruct) && atom[:contents]
            check=atom.to_s
            check.freeze
            fields=[:recType, :recInstance, :contents].map {|sym| bs[sym]}
            saved_values=fields.map {|field| field.get_value}
            a_type=["\x0b\xf0", "\x22\xf1", "\x0f\xf0", "\x0d\xf0"]
            instance=atom[:recInstance].to_s
            a_instance=Generators::RollingCorrupt.new(instance,instance.length*8,instance.length*8,0,:little).to_a.uniq
            contents=atom[:contents]
            rc1=Generators::RollingCorrupt.new(contents.to_s,7,3,32,:little)
            rc2=Generators::RollingCorrupt.new(contents.to_s,5,5,16,:little)
            rc3=Generators::RollingCorrupt.new(contents.to_s,13,5,32,:little)
            g_contents=Generators::Chain.new(rc1,rc2,rc3)
            cartprod=Generators::Cartesian.new(a_type, a_instance, g_contents)
            while cartprod.next?
                new_values=cartprod.next
                fields.zip(new_values) {|field,new_value| field.set_raw(new_value.unpack('B*').join[-field.length..-1])}
                puts "---cartprod start---"
                fields.each {|f| puts atom.inspect[atom.flatten.index(f)]}
                puts "---cartprod finish---" 
                yield 
            end
            fields.zip(saved_values) {|field,saved_value| field.set_value saved_value}
            raise RuntimeError, "DggFuzz2: Data Corruption in cartesian product" unless atom.to_s==check
        end
        atom.each {|atom|
            recursive_cartprod(atom) if atom.is_a? WordStructures::WordDgg
        }
    end

    def seen?( str )
        hsh=Digest::MD5.hexdigest(str)
        seen=@duplicate_check[hsh]
        @duplicate_check[hsh]=true
        @duplicate_check.shift if @duplicate_check.size > SEEN_LIMIT
        seen
    end

    def initialize
        @duplicate_check=Hash.new(false)
        @block=Fiber.new do
            begin
                unmodified=StringIO.new(Template.clone)
                header, raw_fib, rest=unmodifed.read(512),unmodified.read(1472),unmodified.read
                raise RuntimeError, "Data Corruption" unless header+raw_fib+rest == unmodified_file
                fib=WordStructures::WordFIB.new(raw_fib.clone)
                raise RuntimeError, "Data Corruption - fib.to_s not raw_fib" unless fib.to_s == raw_fib
                # Open the file, get a copy of the table stream
                io.rewind
                ole=Ole::Storage.open(io)
                # get the correct table stream 1Table or 0Table
                table_stream=ole.file.read(fib.fWhichTblStm.to_s+"Table")
                ole.close
                fc=:fcDggInfo
                lcb=:lcbDggInfo
                #get the head, fuzztarget and rest from the table stream
                puts "Starting #{fc.to_s}, #{lcb.to_s}, #{fib.send(lcb)}"
                ts_head=table_stream[0,fib.send(fc)]
                fuzztarget=table_stream[fib.send(fc),fib.send(lcb)]
                ts_rest=table_stream[fib.send(fc)+fib.send(lcb)..-1]
                raise RuntimeError, "Data Corruption - TS corrupt" unless (ts_head+fuzztarget+ts_rest)==table_stream
                raise RuntimeError, "Data Corruption - LCB / fuzztarget length mismatch" unless fib.send(lcb)==fuzztarget.length
                begin
                    dgg_parsed=[]
                    fuzzcopy=fuzztarget.clone
                    while fuzzcopy.length > 0
                        dgg_parsed << WordStructures::WordDgg.new(fuzzcopy)
                        if fuzzcopy.length > 0
                            dgg_parsed << Binstruct.new(fuzzcopy.slice!(0,1)) {|buf| unsigned buf, :foo, 8, "thing"}
                        end
                    end
                rescue
                    raise RuntimeError, "DggFuzz: #{$!}"
                end
                raise RuntimeError, "Data Corruption - parsed.join not fuzztarget" unless dgg_parsed.join == fuzztarget
                dgg_parsed.each {|toplevel_struct|
                    next unless toplevel_struct.is_a? WordStructures::WordDgg
                    recursive_cartprod(toplevel_struct) {
                        # the struct pointed to by the entry in dgg_parsed
                        # has already been modified inside the cartprod
                        # function...
                        ts_gunk=dgg_parsed.join
                        next if seen? ts_gunk
                        fuzzed_table=ts_head+ts_gunk+ts_rest
                        io.rewind
                        Ole::Storage.open(io) {|ole|
                            ole.file.open(fib.fWhichTblStm.to_s+"Table", "w+") {|f| f.write fuzzed_table}
                        }
                        io.rewind
                        Fiber.yield io.read
                    }
                }
            rescue
                puts "Production failed: #{$!}";$stdout.flush
                exit
            end
            false
        end
        super
    end
end