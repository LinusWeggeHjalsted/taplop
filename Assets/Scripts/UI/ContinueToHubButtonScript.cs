using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class ContinueToHubButtonScript : MonoBehaviour, IPointerDownHandler
{
    public Button button;

    public void OnPointerDown(PointerEventData eventData)
    {
        SoundControllerScript.Instance.PlayButtonClickDownSound();
    }

    public void OnActivate()
    {
        GameControllerScript.Instance.EnterHub(MissionLogicScript.Instance.endHub);
        SoundControllerScript.Instance.PlayButtonClickUpSound();
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
    }
}
