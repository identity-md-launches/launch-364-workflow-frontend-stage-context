import { useEffect, useState } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
import { loadConfig, type Config } from './config';
import { errorMessage } from './game';
import './styles.css';

function Root() {
  const [config, setConfig] = useState<Config>();
  const [error, setError] = useState('');
  useEffect(() => { loadConfig().then(setConfig).catch(e => setError(errorMessage(e))); }, []);
  if (!config) return <main className="boot wrap"><span className="brand">heads.</span><h1>{error ? 'Deployment unavailable' : 'Preparing the table…'}</h1><p role={error ? 'alert' : 'status'}>{error || 'Loading the deployment and verifying contract interfaces.'}</p>{error && <button onClick={() => location.reload()}>Reload deployment</button>}</main>;
  return <App config={config}/>;
}
createRoot(document.getElementById('root')!).render(<Root/>);
