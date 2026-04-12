using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class ContinueButtonScript : MonoBehaviour, IPointerDownHandler
{
    public Button button;
    public GameObject optionsMenu;

    public void OnPointerDown(PointerEventData eventData)
    {
        SoundControllerScript.Instance.PlayButtonClickDownSound();
    }

    public void OnActivate()
    {
        SoundControllerScript.Instance.PlayButtonClickUpSound();
        Destroy(optionsMenu);
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        optionsMenu = GameObject.Find("Options Menu(Clone)");
    }
}
