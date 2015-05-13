module Ltree
  module Hierarchy
    def has_ltree_hierarchy(options = {})
      options = {
        :fragment => :id,
        :parent_fragment => :parent_id,
        :path => :path
      }.merge(options)

      options.assert_valid_keys(:fragment, :parent_fragment, :path)

      cattr_accessor :ltree_fragment_column, :ltree_parent_fragment_column, :ltree_path_column

      self.ltree_fragment_column        = options[:fragment]
      self.ltree_parent_fragment_column = options[:parent_fragment]
      self.ltree_path_column            = options[:path]

      belongs_to :parent, :class_name => self.name, :foreign_key => self.ltree_parent_fragment_column

      validate :prevent_circular_paths, :if => :ltree_parent_fragment_changed?

      after_create  :commit_path
      before_update :assign_path, :cascade_path_change, :if => :ltree_parent_fragment_changed?

      include InstanceMethods
    end

    def roots
      where(self.ltree_parent_fragment_column => nil)
    end

    def at_depth(depth)
      where(["nlevel(#{ltree_path_column}) = ?", depth])
    end

    def leaves
      subquery = select("DISTINCT #{ltree_parent_fragment_column}")
      where("#{ltree_fragment_column} NOT IN(#{subquery.to_sql})")
    end

    def lowest_common_ancestor_paths(paths)
      sql = if paths.respond_to?(:to_sql)
        "SELECT lca(array(#{paths.to_sql}))"
      else
        return [] if paths.empty?
        safe_paths = paths.map { |p| "#{connection.quote(p)}::ltree" }
        "SELECT lca(ARRAY[#{safe_paths.join(', ')}])"
      end
      connection.select_values(sql)
    end

    def lowest_common_ancestors(paths)
      where(ltree_path_column => lowest_common_ancestor_paths(paths))
    end

    module InstanceMethods
      def ltree_scope
        self.class.base_class
      end

      def ltree_fragment_column
        self.class.ltree_fragment_column
      end

      def ltree_fragment
        send(self.ltree_fragment_column)
      end

      def ltree_parent_fragment_column
        self.class.ltree_parent_fragment_column
      end

      def ltree_parent_fragment
        send(ltree_parent_fragment_column)
      end

      def ltree_parent_fragment_changed?
        changed_attributes.key?(ltree_parent_fragment_column.to_s)
      end

      def ltree_path_column
        self.class.ltree_path_column
      end

      def ltree_path
        send(ltree_path_column)
      end

      def ltree_path_was
        send("#{ltree_path_column}_was")
      end

      def prevent_circular_paths
        if parent && parent.ltree_path.split('.').include?(ltree_fragment.to_s)
          errors.add(ltree_parent_fragment_column, :invalid)
        end
      end

      def compute_path
        if parent
          "#{parent.ltree_path}.#{ltree_fragment}"
        else
          ltree_fragment.to_s
        end
      end

      def assign_path
        self.send("#{ltree_path_column}=", compute_path)
      end

      def commit_path
        update_column(ltree_path_column, compute_path)
      end

      def cascade_path_change
        # Typically equivalent to:
        #  UPDATE whatever
        #  SET    path = NEW.path || subpath(path, nlevel(OLD.path))
        #  WHERE  path <@ OLD.path AND id != NEW.id;
        ltree_scope.where(
          ["#{ltree_path_column} <@ :old_path AND #{ltree_fragment_column} != :id", :old_path => ltree_path_was, :id => ltree_fragment]
        ).update_all(
          ["#{ltree_path_column} = :new_path || subpath(#{ltree_path_column}, nlevel(:old_path))", :new_path => ltree_path, :old_path => ltree_path_was]
        )
      end

      def root?
        if self.ltree_parent_fragment
          false
        else
          parent.nil?
        end
      end

      def leaf?
        !children.exists?
      end

      def depth # 1-based, for compatibility with ltree's nlevel().
        if root?
          1
        elsif ltree_path
          ltree_path.split('.').length
        elsif parent
          parent.depth + 1
        end
      end

      def ancestors
        ltree_scope.where("#{self.class.table_name}.#{ltree_path_column} @> ? AND #{self.class.table_name}.#{ltree_fragment_column} != ?", ltree_path, ltree_fragment)
      end

      def self_and_ancestors
        ltree_scope.where("#{self.class.table_name}.#{ltree_path_column} @> ?", ltree_path)
      end
      alias :and_ancestors :self_and_ancestors

      def siblings
        ltree_scope.where("#{ltree_parent_fragment_column} = ? AND #{self.class.table_name}.#{ltree_fragment_column} != ?", ltree_parent_fragment, ltree_fragment)
      end

      def self_and_siblings
        ltree_scope.where(ltree_parent_fragment_column => ltree_parent_fragment)
      end
      alias :and_siblings :self_and_siblings

      def descendents
        ltree_scope.where("#{self.class.table_name}.#{ltree_path_column} <@ ? AND #{self.class.table_name}.#{ltree_fragment_column} != ?", ltree_path, ltree_fragment)
      end

      def self_and_descendents
        ltree_scope.where("#{self.class.table_name}.#{ltree_path_column} <@ ?", ltree_path)
      end
      alias :and_descendents :self_and_descendents

      def children
        ltree_scope.where(ltree_parent_fragment_column => ltree_fragment)
      end

      def self_and_children
        ltree_scope.where("#{ltree_fragment_column} = :id OR #{ltree_parent_fragment_column} = :id", :id => ltree_fragment)
      end
      alias :and_children :self_and_children

      def leaves
        descendents.leaves
      end
    end
  end
end
