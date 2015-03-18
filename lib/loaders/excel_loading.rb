# Copyright:: (c) Autotelik Media Ltd 2011
# Author ::   Tom Statter
# Date ::     Aug 2011
# License::   MIT
#
# Details::   Specific loader to support Excel files.
#             Note this only requires JRuby, Excel not required, nor Win OLE.
#
#             Maps column headings to operations on the model.
#             Iterates over all the rows using mapped operations to assign row data to a database object,
#             i.e pulls data from each column and sends to object.
#
module DataShift


  module ExcelLoading

    include ExcelBase


    #  Options  :
    #
    #   [:sheet_number]    : Default is 0. The index of the Excel Worksheet to use.
    #   [:header_row]      : Default is 0. Use alternative row as header definition.
    #
    def start( file_name, options = {} )

      puts "\n\nStarting Load from Excel file: #{file_name}"
      logger.info("\nStarting Load from Excel file: #{file_name}")

      start_excel(file_name, options[:sheet_number] || 0 )

      doc_context.headers = parse_headers(sheet, options[:header_row] || 0)

      raise MissingHeadersError, "No headers found - Check Sheet #{sheet} is complete and Row #{doc_context.headers.idx} contains headers" if(headers.empty?)

      # maps list of headers into suitable calls on the Active Record class
      bind_headers(headers, options )

      excel
    end

    #  Options
    #
    #   [:allow_empty_rows]  : Default is to stop processing once we hit a completely empty row. Over ride.
    #                          WARNING maybe slow, as will process all rows as defined by Excel
    #
    #   [:dummy]           : Perform a dummy run - attempt to load everything but then roll back
    #  
    #   [:sheet_number]    : Default is 0. The index of the Excel Worksheet to use.
    #   [:header_row]      : Default is 0. Use alternative row as header definition.
    #   
    #  Options passed through  to :  populate_method_mapper_from_headers
    #  
    #   [:mandatory]       : Array of mandatory column names
    #   [:force_inclusion] : Array of inbound column names to force into mapping
    #   [:include_all]     : Include all headers in processing - takes precedence of :force_inclusion
    #   [:strict]          : Raise exception when no mapping found for a column heading (non mandatory)

    def perform_excel_load( file_name, options = {} )

      raise MissingHeadersError, "Minimum row for Headers is 0 - passed #{options[:header_row]}" if(options[:header_row] && options[:header_row].to_i < 0)

      allow_empty_rows = options[:allow_empty_rows]

      start(file_name, options)

      begin
        puts "Dummy Run - Changes will be rolled back" if options[:dummy]

        load_object_class.transaction do

          sheet.each_with_index do |row, i|

            current_row_idx = i

            doc_context.current_row = row

            next if(current_row_idx == headers.idx)

            # Excel num_rows seems to return all 'visible' rows, which appears to be greater than the actual data rows
            # (TODO - write spec to process .xls with a huge number of rows)
            #
            # manually have to detect when actual data ends, this isn't very smart but
            # got no better idea than ending once we hit the first completely empty row
            break if(!allow_empty_rows && (row.nil? || row.empty?))

            logger.info "Processing Row #{i} : #{@current_row}"

            contains_data = false

            # Iterate over the bindings, creating a context from data in associated Excel column

            @binder.bindings.each_with_index do |method_binding, i|

              unless(method_binding.valid?)
                logger.warn("No binding was found for column (#{i})") if(verbose)
                next
              end

              value = row[method_binding.inbound_index]   #binding contains column number

              context = doc_context.create_context(method_binding, i, value)

              contains_data ||= context.contains_data?

              puts "Processing Column #{method_binding.inbound_index} (#{method_binding.pp})"
              logger.info "Processing Column #{method_binding.inbound_index} (#{method_binding.pp})"

              begin
                context.process
              rescue => x

                doc_context.errors << "Failed to process node #{method_binding.inspect}"

                puts x.backtrace.first, x.message

                logger.error("#{x.backtrace.first} : #{x.message}")

                logger.error("Failed to process node #{method_binding.inspect}")

                if(doc_context.all_or_nothing?)
                  logger.error("Failed to process node #{method_binding.inspect} - Current row aborted")
                  break
                else
                  logger.warn("Failed to process node #{method_binding.inspect} - Continuing")
                end

              end

            end

            # manually have to detect when actual data ends
            break if(!allow_empty_rows && contains_data == false)

            unless(doc_context.errors? && doc_context.all_or_nothing?)
              doc_context.save_and_report
            end


            unless(doc_context.context.next_update?)
              doc_context.reset
            end

          end   # all rows processed

          if(options[:dummy])
            puts "Excel loading stage complete - Dummy run so Rolling Back."
            raise ActiveRecord::Rollback # Don't actually create/upload to DB if we are doing dummy run
          end

        end   # TRANSACTION N.B ActiveRecord::Rollback does not propagate outside of the containing transaction block

      rescue => e
        puts "ERROR: Excel loading failed : #{e.inspect}"
        raise e
      ensure
        report
      end

    end


  end

end