# encoding: utf-8
module ActsAsTaggableOn
  class Tag < ::ActiveRecord::Base

    ### ASSOCIATIONS:

    has_many :taggings, dependent: :destroy, class_name: '::ActsAsTaggableOn::Tagging'

    ### VALIDATIONS:

    validates_presence_of :name
    validates_uniqueness_of :name, scope: :company_id, if: :validates_name_uniqueness?
    validates_length_of :name, maximum: 255

    # monkey patch this method if don't need name uniqueness validation
    def validates_name_uniqueness?
      true
    end

    ### SCOPES:
    scope :most_used, ->(company_id, limit = 20) { where(company_id: company_id).order('taggings_count desc').limit(limit) }
    scope :least_used, ->(company_id, limit = 20) { where(company_id: company_id).order('taggings_count asc').limit(limit) }

    def self.named(name, company_id)
      if ActsAsTaggableOn.strict_case_match
        where(["name = #{binary}?", as_8bit_ascii(name)])
      else
        where(['LOWER(name) = LOWER(?)', as_8bit_ascii(unicode_downcase(name))])
      end.where(company_id: company_id)
    end

    def self.named_any(list, company_id)
      clause = list.map { |tag|
        sanitize_sql_for_named_any(tag).force_encoding('BINARY')
      }.join(' OR ')
      where(clause).where(company_id: company_id)
    end

    def self.named_like(name, company_id)
      clause = ["name #{ActsAsTaggableOn::Utils.like_operator} ? ESCAPE '!'", "%#{ActsAsTaggableOn::Utils.escape_like(name)}%"]
      where(clause).where(company_id: company_id)
    end

    def self.named_like_any(list, company_id)
      clause = list.map { |tag|
        sanitize_sql(["name #{ActsAsTaggableOn::Utils.like_operator} ? ESCAPE '!'", "%#{ActsAsTaggableOn::Utils.escape_like(tag.to_s)}%"])
      }.join(' OR ')
      where(clause).where(company_id: company_id)
    end

    def self.for_context(context, company_id)
      joins(:taggings).
        where(["taggings.context = ?", context]).
        where(company_id: company_id).
        select("DISTINCT tags.*")
    end

    ### CLASS METHODS:

    def self.find_or_create_with_like_by_name(name, company_id)
      if ActsAsTaggableOn.strict_case_match
        self.find_or_create_all_with_like_by_name([name], company_id: company_id).first
      else
        named_like(name, company_id).first || create(name: name, company_id: company_id)
      end
    end

    def self.find_or_create_all_with_like_by_name(*list)
      list = Array(list).flatten
      if !list.last.is_a?(Hash) || list.last[:company_id].blank?
        raise "find_or_create_all_with_like_by_name expects company_id"
      end
      company_id = list.pop[:company_id]

      return [] if list.empty?

      list.map do |tag_name|
        begin
          tries ||= 3

          existing_tags = named_any(list, company_id)
          comparable_tag_name = comparable_name(tag_name)
          existing_tag = existing_tags.find { |tag| comparable_name(tag.name) == comparable_tag_name }
          existing_tag || create(name: tag_name, company_id: company_id)
        rescue ActiveRecord::RecordNotUnique
          if (tries -= 1).positive?
            ActiveRecord::Base.connection.execute 'ROLLBACK'
            retry
          end

          raise DuplicateTagError.new("'#{tag_name}' has already been taken")
        end
      end
    end

    ### INSTANCE METHODS:

    def ==(object)
      super || (object.is_a?(Tag) && name == object.name)
    end

    def to_s
      name
    end

    def count
      read_attribute(:count).to_i
    end

    class << self



      private

      def comparable_name(str)
        if ActsAsTaggableOn.strict_case_match
          str
        else
          unicode_downcase(str.to_s)
        end
      end

      def binary
        ActsAsTaggableOn::Utils.using_mysql? ? 'BINARY ' : nil
      end

      def unicode_downcase(string)
        if ActiveSupport::Multibyte::Unicode.respond_to?(:downcase)
          ActiveSupport::Multibyte::Unicode.downcase(string)
        else
          ActiveSupport::Multibyte::Chars.new(string).downcase.to_s
        end
      end

      def as_8bit_ascii(string)
        if defined?(Encoding)
          string.to_s.dup.force_encoding('BINARY')
        else
          string.to_s.mb_chars
        end
      end

      def sanitize_sql_for_named_any(tag)
        if ActsAsTaggableOn.strict_case_match
          sanitize_sql(["name = #{binary}?", as_8bit_ascii(tag)])
        else
          sanitize_sql(['LOWER(name) = LOWER(?)', as_8bit_ascii(unicode_downcase(tag))])
        end
      end
    end
  end
end
