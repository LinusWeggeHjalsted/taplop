using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class ContinueToHubButtonScript : MonoBehaviour
{
    public Button button;
    
    public void OnActivate()
    {
        GameControllerScript.Instance.EnterHub(MissionLogicScript.Instance.endHub);
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
    }
}
