# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CanvasBuilder do
  describe '#initialize' do
    it 'creates a builder with dimensions' do
      builder = CanvasBuilder.new(width: 200, height: 150)
      expect(builder.width).to eq(200)
      expect(builder.height).to eq(150)
    end
  end

  describe '#render' do
    it 'outputs canvas format with dimensions and commands' do
      builder = CanvasBuilder.new(width: 200, height: 150)
      builder.filled_rect(x: 0, y: 0, width: 200, height: 150, color: '#000000')

      result = builder.render
      parts = result.split('|||')

      expect(parts[0]).to eq('200')
      expect(parts[1]).to eq('150')
      expect(parts[2]).to include('frect::#000000')
    end
  end

  describe '#use_palette' do
    it 'sets palette for symbol color resolution' do
      builder = CanvasBuilder.new(width: 100, height: 100)
      builder.use_palette(:minimap)
      builder.filled_rect(x: 0, y: 0, width: 100, height: 100, color: :background)

      result = builder.render
      expect(result).to include('#0a0a0a')
    end

    it 'returns self for chaining' do
      builder = CanvasBuilder.new(width: 100, height: 100)
      expect(builder.use_palette(:minimap)).to eq(builder)
    end
  end

  describe 'drawing commands' do
    let(:builder) { CanvasBuilder.new(width: 200, height: 200) }

    describe '#line' do
      it 'generates line command' do
        builder.line(x1: 10, y1: 20, x2: 50, y2: 60, color: '#ff0000')
        expect(builder.render).to include('line::#ff0000,10,20,50,60')
      end
    end

    describe '#dashed_line' do
      it 'generates dashed line command' do
        builder.dashed_line(x1: 10, y1: 20, x2: 50, y2: 60, color: '#ff0000', dash_length: 5, gap_length: 3)
        expect(builder.render).to include('dashed::#ff0000,10,20,50,60,5,3')
      end
    end

    describe '#rect' do
      it 'generates rect command' do
        builder.rect(x: 10, y: 20, width: 50, height: 60, color: '#ff0000')
        expect(builder.render).to include('rect::#ff0000,10,20,60,80')
      end
    end

    describe '#filled_rect' do
      it 'generates frect command' do
        builder.filled_rect(x: 10, y: 20, width: 50, height: 60, color: '#ff0000')
        expect(builder.render).to include('frect::#ff0000,10,20,60,80')
      end

      it 'registers hit region when id provided' do
        builder.filled_rect(x: 10, y: 20, width: 50, height: 60, color: '#ff0000',
                            id: 'test_region', data: { tooltip: 'Test' })
        expect(builder.hit_regions).to include(
          hash_including(id: 'test_region', shape: 'rect')
        )
      end
    end

    describe '#rounded_rect' do
      it 'generates roundrect command' do
        builder.rounded_rect(x: 10, y: 20, width: 50, height: 60, radius: 5, color: '#ff0000')
        expect(builder.render).to include('roundrect::#ff0000,10,20,60,80,5')
      end
    end

    describe '#filled_rounded_rect' do
      it 'generates froundrect command' do
        builder.filled_rounded_rect(x: 10, y: 20, width: 50, height: 60, radius: 5, color: '#ff0000')
        expect(builder.render).to include('froundrect::#ff0000,10,20,60,80,5')
      end
    end

    describe '#circle' do
      it 'generates circle command' do
        builder.circle(cx: 100, cy: 100, radius: 50, color: '#00ff00')
        expect(builder.render).to include('circle::#00ff00,100,100,50')
      end
    end

    describe '#filled_circle' do
      it 'generates fcircle command' do
        builder.filled_circle(cx: 100, cy: 100, radius: 50, color: '#00ff00')
        expect(builder.render).to include('fcircle::#00ff00,100,100,50')
      end

      it 'registers hit region when id provided' do
        builder.filled_circle(cx: 100, cy: 100, radius: 50, color: '#00ff00',
                              id: 'circle_region', data: { action: 'navigate', command: 'north' })
        expect(builder.hit_regions).to include(
          hash_including(id: 'circle_region', shape: 'circle', cx: 100, cy: 100, radius: 50)
        )
      end
    end

    describe '#arc' do
      it 'generates arc command' do
        builder.arc(cx: 100, cy: 100, radius: 50, start_angle: 0, end_angle: 90, color: '#0000ff')
        expect(builder.render).to include('arc::#0000ff,100,100,50,0,90')
      end
    end

    describe '#polygon' do
      it 'generates poly command' do
        builder.polygon(points: [[10, 10], [50, 10], [30, 50]], color: '#ff00ff')
        expect(builder.render).to include('poly::#ff00ff,10,10,50,10,30,50')
      end
    end

    describe '#filled_polygon' do
      it 'generates fpoly command' do
        builder.filled_polygon(points: [[10, 10], [50, 10], [30, 50]], color: '#ff00ff')
        expect(builder.render).to include('fpoly::#ff00ff,10,10,50,10,30,50')
      end

      it 'registers hit region when id provided' do
        builder.filled_polygon(points: [[10, 10], [50, 10], [30, 50]], color: '#ff00ff',
                               id: 'poly_region', data: { tooltip: 'Triangle' })
        expect(builder.hit_regions).to include(
          hash_including(id: 'poly_region', shape: 'polygon')
        )
      end
    end

    describe '#gradient_rect' do
      it 'generates gradient command with vertical direction' do
        builder.gradient_rect(x: 10, y: 20, width: 100, height: 50,
                              color1: '#ff0000', color2: '#0000ff', direction: :vertical)
        expect(builder.render).to include('gradient::#ff0000,#0000ff,v,10,20,110,70')
      end

      it 'generates gradient command with horizontal direction' do
        builder.gradient_rect(x: 10, y: 20, width: 100, height: 50,
                              color1: '#ff0000', color2: '#0000ff', direction: :horizontal)
        expect(builder.render).to include('gradient::#ff0000,#0000ff,h,10,20,110,70')
      end

      it 'generates gradient command with diagonal direction' do
        builder.gradient_rect(x: 10, y: 20, width: 100, height: 50,
                              color1: '#ff0000', color2: '#0000ff', direction: :diagonal)
        expect(builder.render).to include('gradient::#ff0000,#0000ff,d,10,20,110,70')
      end
    end

    describe '#text' do
      it 'generates text command' do
        builder.text(x: 100, y: 50, text: 'Hello')
        expect(builder.render).to include('text::100,50||sans-serif||Hello')
      end

      it 'generates coltext command when color provided' do
        builder.text(x: 100, y: 50, text: 'Hello', color: '#ffffff')
        expect(builder.render).to include('coltext::#ffffff,100,50||sans-serif||Hello')
      end

      it 'sanitizes text' do
        builder.text(x: 100, y: 50, text: 'Hello|World;Test:End')
        result = builder.render
        expect(result).not_to include('|World')
        expect(result).to include('Hello World Test End')
      end
    end

    describe '#text_in_rect' do
      it 'generates textrect command' do
        builder.text_in_rect(x1: 10, y1: 20, x2: 100, y2: 50, text: 'Fit me')
        expect(builder.render).to include('textrect::10,20,100,50||sans-serif||Fit me')
      end
    end

    describe '#rotated_text' do
      it 'generates vtext command' do
        builder.rotated_text(x: 100, y: 50, text: 'Vertical', angle: -90, color: '#ffffff')
        expect(builder.render).to include('vtext::#ffffff,100,50,-90||sans-serif||Vertical')
      end
    end

    describe '#image' do
      it 'generates img command' do
        builder.image(url: '/images/test.png', x: 10, y: 20, width: 50, height: 50)
        expect(builder.render).to include('img::/images/test.png,10,20,50,50')
      end
    end
  end

  describe '#layer' do
    it 'groups commands by layer' do
      builder = CanvasBuilder.new(width: 200, height: 200)

      builder.layer(:background) do |c|
        c.filled_rect(x: 0, y: 0, width: 200, height: 200, color: '#000000')
      end

      builder.layer(:entities) do |c|
        c.filled_circle(cx: 100, cy: 100, radius: 20, color: '#ff0000')
      end

      result = builder.render
      # Background should come before entities
      bg_pos = result.index('#000000')
      entity_pos = result.index('#ff0000')
      expect(bg_pos).to be < entity_pos
    end

    it 'collects hit regions from layers' do
      builder = CanvasBuilder.new(width: 200, height: 200)

      builder.layer(:entities) do |c|
        c.filled_circle(cx: 100, cy: 100, radius: 20, color: '#ff0000',
                        id: 'layer_circle', data: { tooltip: 'Test' })
      end

      expect(builder.hit_regions).to include(
        hash_including(id: 'layer_circle')
      )
    end
  end

  describe '#set_transform' do
    it 'inverts Y coordinates with :invert_y' do
      builder = CanvasBuilder.new(width: 200, height: 200)
      builder.set_transform(:invert_y, max_y: 200)
      builder.filled_rect(x: 10, y: 20, width: 50, height: 30, color: '#ff0000')

      result = builder.render
      # Y should be inverted: 200 - 20 = 180
      expect(result).to include('frect::#ff0000,10,180')
    end
  end

  describe '#render with hit regions' do
    it 'includes base64 encoded hit regions when requested' do
      builder = CanvasBuilder.new(width: 200, height: 200)
      builder.filled_rect(x: 10, y: 20, width: 50, height: 60, color: '#ff0000',
                          id: 'test', data: { tooltip: 'Test tooltip' })

      result = builder.render(include_hit_regions: true)
      parts = result.split('|||')

      expect(parts.length).to eq(4)
      decoded = JSON.parse(Base64.decode64(parts[3]))
      expect(decoded).to be_an(Array)
      expect(decoded.first['id']).to eq('test')
    end

    it 'excludes hit regions by default' do
      builder = CanvasBuilder.new(width: 200, height: 200)
      builder.filled_rect(x: 10, y: 20, width: 50, height: 60, color: '#ff0000',
                          id: 'test', data: { tooltip: 'Test' })

      result = builder.render
      parts = result.split('|||')

      expect(parts.length).to eq(3)
    end
  end

  describe 'palettes' do
    it 'has minimap palette' do
      expect(CanvasBuilder::PALETTES[:minimap]).to include(:background, :current_room)
    end

    it 'has roommap palette' do
      expect(CanvasBuilder::PALETTES[:roommap]).to include(:background, :wall, :floor)
    end

    it 'has areamap palette' do
      expect(CanvasBuilder::PALETTES[:areamap]).to include(:background, :building, :ocean, :forest)
    end

    it 'has delve palette' do
      expect(CanvasBuilder::PALETTES[:delve]).to include(:corridor, :chamber, :monster)
    end
  end

  describe 'command chaining' do
    it 'returns self for all drawing methods' do
      builder = CanvasBuilder.new(width: 200, height: 200)

      result = builder
               .line(x1: 0, y1: 0, x2: 100, y2: 100, color: '#ff0000')
               .filled_rect(x: 10, y: 10, width: 50, height: 50, color: '#00ff00')
               .filled_circle(cx: 100, cy: 100, radius: 20, color: '#0000ff')
               .text(x: 50, y: 50, text: 'Test')

      expect(result).to eq(builder)
    end
  end
end
