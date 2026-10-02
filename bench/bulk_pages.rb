# frozen_string_literal: true

# Fixture generation only: keep the same page content, insert trigger and bounds
# without constructing every repeated page in Ruby.
class BulkPages
  def initialize(db, texts)
    @db, @samples = db, texts.size
    @db.execute("CREATE TEMP TABLE benchmark_samples(id INTEGER PRIMARY KEY, content TEXT)")
    @db.transaction do
      @db.prepare("INSERT INTO benchmark_samples VALUES (?, ?)") do |statement|
        texts.each_with_index { |text, index| statement.execute(index, text) }
      end
    end
  end

  def add(file_id, start, numbers)
    first, last = start + numbers.first + 1, start + numbers.last + 1
    @db.transaction do
      @db.execute(<<~SQL, [first, last, file_id, start, @samples])
        WITH RECURSIVE sequence(id) AS (
          SELECT ? UNION ALL SELECT id + 1 FROM sequence WHERE id < ?
        )
        INSERT INTO pages(id, file_id, number, content)
        SELECT sequence.id, ?, sequence.id - ?, samples.content || char(10) || sequence.id
        FROM sequence JOIN benchmark_samples samples ON samples.id = (sequence.id * 7919) % ?
      SQL
      @db.execute("UPDATE files SET first_page_id = min(coalesce(first_page_id, ?), ?), last_page_id = max(coalesce(last_page_id, ?), ?) WHERE id = ?", [first, first, last, last, file_id])
    end
  end
end
