// If rendering ever throws (a scene the checks didn't catch), show what
// happened and a way back instead of a blank page.
import {Component, type ReactNode} from 'react';
import {Button} from '@astryxdesign/core/Button';
import {VStack} from '@astryxdesign/core/Layout';
import {Heading, Text} from '@astryxdesign/core/Text';

export class ErrorBoundary extends Component<{children: ReactNode}, {error: Error | null}> {
  state = {error: null as Error | null};

  static getDerivedStateFromError(error: Error) {
    return {error};
  }

  render() {
    if (!this.state.error) return this.props.children;
    return (
      <div className="crash">
        <VStack gap={3}>
          <Heading level={2}>Fringe Web couldn't show this scene</Heading>
          <Text type="supporting">{this.state.error.message}</Text>
          <div>
            <Button
              label="Open the lens example"
              variant="primary"
              onClick={() => {
                history.replaceState(null, '', '#ex=lens');
                location.reload();
              }}
            />
          </div>
        </VStack>
      </div>
    );
  }
}
